import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/providers.dart';
import 'package:jarvis/features/assistant/application/text_assistant_controller.dart';
import 'package:jarvis/features/assistant/application/text_assistant_state.dart';
import 'package:jarvis/features/assistant/data/assistant_api.dart';
import 'package:jarvis/features/auth/application/auth_controller.dart';
import 'package:jarvis/features/auth/application/auth_state.dart';

import '../../../support/fake_assistant_api.dart';
import '../../../support/fake_auth_api.dart';
import '../../../support/in_memory_token_store.dart';

typedef _Harness = ({
  ProviderContainer container,
  FakeAssistantApi api,
  InMemoryTokenStore store,
  List<TextAssistantState> states,
  ProviderSubscription<TextAssistantState> subscription,
});

/// A signed-in container with the controller kept alive by a listener that
/// records every state.
Future<_Harness> _setUp() async {
  final api = FakeAssistantApi();
  final store = InMemoryTokenStore(testSession());
  final container = ProviderContainer.test(
    retry: (_, _) => null,
    overrides: [
      authApiProvider.overrideWithValue(FakeAuthApi()),
      tokenStoreProvider.overrideWithValue(store),
      clockProvider.overrideWithValue(() => DateTime.utc(2026, 10, 5)),
      assistantApiProvider.overrideWithValue(api),
    ],
  );
  container.read(authControllerProvider);
  await _flush();
  expect(container.read(authControllerProvider), isA<AuthAuthenticated>());

  final states = <TextAssistantState>[];
  final subscription = container.listen(
    textAssistantControllerProvider,
    (_, next) => states.add(next),
    fireImmediately: true,
  );
  return (
    container: container,
    api: api,
    store: store,
    states: states,
    subscription: subscription,
  );
}

Future<void> _flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

TextAssistantController _controller(ProviderContainer container) =>
    container.read(textAssistantControllerProvider.notifier);

void main() {
  test('starts idle', () async {
    final h = await _setUp();

    expect(h.states, [isA<TextAssistantIdle>()]);
  });

  test('idle -> submitting -> success', () async {
    final h = await _setUp();

    await _controller(h.container).submit('Hello');

    expect(h.states, [
      isA<TextAssistantIdle>(),
      isA<TextAssistantSubmitting>(),
      isA<TextAssistantSuccess>().having(
        (s) => s.reply,
        'reply',
        FakeAssistantApi.defaultReply,
      ),
    ]);
  });

  for (final failure in AssistantFailure.values.where(
    (f) => f != AssistantFailure.sessionExpired,
  )) {
    test('idle -> submitting -> failure(${failure.name})', () async {
      final h = await _setUp();
      h.api.onRespond = (_) => Future.error(assistantError(failure));

      await _controller(h.container).submit('Hello');

      expect(h.states, [
        isA<TextAssistantIdle>(),
        isA<TextAssistantSubmitting>(),
        isA<TextAssistantFailure>().having(
          (s) => s.failure,
          'failure',
          failure,
        ),
      ]);
    });
  }

  test('an unexpected non-API error becomes failure(unexpected)', () async {
    final h = await _setUp();
    h.api.onRespond = (_) => Future.error(const FakeStorageException('read'));

    await _controller(h.container).submit('Hello');

    expect(
      h.states.last,
      isA<TextAssistantFailure>().having(
        (s) => s.failure,
        'failure',
        AssistantFailure.unexpected,
      ),
    );
  });

  group('validation', () {
    for (final (name, text) in [
      ('empty', ''),
      ('whitespace-only', ' \n\t  '),
      ('4001 characters', 'x' * 4001),
      ('4001 emoji', '🤖' * 4001),
    ]) {
      test('$name is ignored', () async {
        final h = await _setUp();

        await _controller(h.container).submit(text);

        expect(h.api.messages, isEmpty);
        expect(h.states, [isA<TextAssistantIdle>()]);
      });
    }

    test('4000 characters are accepted', () async {
      final h = await _setUp();

      await _controller(h.container).submit('x' * 4000);

      expect(h.api.messages.single.length, 4000);
    });

    test('an emoji counts as one character', () async {
      final h = await _setUp();
      // 4000 code points, but 8000 UTF-16 code units.
      final text = '🤖' * 4000;
      expect(text.length, 8000);
      expect(assistantMessageLength(text), 4000);

      await _controller(h.container).submit(text);

      expect(h.api.messages, [text]);
    });

    test('surrounding whitespace does not count and is not sent', () async {
      final h = await _setUp();

      await _controller(h.container).submit('  \n${'x' * 4000}\t ');

      expect(h.api.messages.single, 'x' * 4000);
    });

    test('the message is trimmed before it is sent', () async {
      final h = await _setUp();

      await _controller(h.container).submit('  hello\nJarvis  \n');

      expect(h.api.messages, ['hello\nJarvis']);
    });
  });

  test('a second submit while in flight is ignored', () async {
    final h = await _setUp();
    final pending = Completer<String>();
    h.api.onRespond = (_) => pending.future;

    final first = _controller(h.container).submit('first');
    await _controller(h.container).submit('second');
    pending.complete('reply');
    await first;

    expect(h.api.messages, ['first']);
    expect(h.states.whereType<TextAssistantSubmitting>(), hasLength(1));
  });

  test('a new submit clears the previous success', () async {
    final h = await _setUp();
    await _controller(h.container).submit('first');
    final pending = Completer<String>();
    h.api.onRespond = (_) => pending.future;

    final second = _controller(h.container).submit('second');

    expect(
      h.container.read(textAssistantControllerProvider),
      isA<TextAssistantSubmitting>(),
    );
    pending.complete('second reply');
    await second;
    expect(
      h.container.read(textAssistantControllerProvider),
      isA<TextAssistantSuccess>().having(
        (s) => s.reply,
        'reply',
        'second reply',
      ),
    );
  });

  test('a new submit clears the previous failure', () async {
    final h = await _setUp();
    h.api.onRespond = (_) =>
        Future.error(assistantError(AssistantFailure.busy));
    await _controller(h.container).submit('first');
    h.api.onRespond = null;

    await _controller(h.container).submit('second');

    expect(h.states.skip(2), [
      isA<TextAssistantFailure>(),
      isA<TextAssistantSubmitting>(),
      isA<TextAssistantSuccess>(),
    ]);
  });

  group('session expired', () {
    test('signs out through AuthController without a failure state', () async {
      final h = await _setUp();
      h.api.onRespond = (_) =>
          Future.error(assistantError(AssistantFailure.sessionExpired));

      await _controller(h.container).submit('Hello');

      expect(
        h.container.read(authControllerProvider),
        isA<AuthUnauthenticated>(),
      );
      expect(h.store.session, isNull);
      expect(h.states.whereType<TextAssistantFailure>(), isEmpty);
    });

    test('still clears the session if the screen was closed', () async {
      final h = await _setUp();
      final pending = Completer<String>();
      h.api.onRespond = (_) => pending.future;

      final request = _controller(h.container).submit('Hello');
      h.subscription.close();
      await _flush();
      pending.completeError(assistantError(AssistantFailure.sessionExpired));
      await request;

      expect(
        h.container.read(authControllerProvider),
        isA<AuthUnauthenticated>(),
      );
      expect(h.store.session, isNull);
    });
  });

  group('dispose', () {
    test('a result arriving after dispose is discarded', () async {
      final h = await _setUp();
      final pending = Completer<String>();
      h.api.onRespond = (_) => pending.future;

      final request = _controller(h.container).submit('Hello');
      h.subscription.close();
      await _flush();
      pending.complete('late reply');
      await request;

      expect(h.states.last, isA<TextAssistantSubmitting>());
      // Recreated from scratch: nothing carried over.
      expect(
        h.container.read(textAssistantControllerProvider),
        isA<TextAssistantIdle>(),
      );
    });

    test('a failure arriving after dispose is discarded', () async {
      final h = await _setUp();
      final pending = Completer<String>();
      h.api.onRespond = (_) => pending.future;

      final request = _controller(h.container).submit('Hello');
      h.subscription.close();
      await _flush();
      pending.completeError(assistantError(AssistantFailure.unavailable));
      await request;

      expect(
        h.container.read(textAssistantControllerProvider),
        isA<TextAssistantIdle>(),
      );
    });

    test('recreated after a success it starts idle', () async {
      final h = await _setUp();
      await _controller(h.container).submit('Hello');
      h.subscription.close();
      await _flush();

      expect(
        h.container.read(textAssistantControllerProvider),
        isA<TextAssistantIdle>(),
      );
    });
  });
}
