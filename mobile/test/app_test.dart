import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth_api.dart';
import 'support/in_memory_token_store.dart';
import 'support/test_app.dart';

void main() {
  testWidgets('JarvisApp starts on splash and shows login when signed out', (
    tester,
  ) async {
    await pumpJarvis(tester, api: FakeAuthApi(), store: InMemoryTokenStore());

    expect(find.text('Jarvis'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login-email')), findsOneWidget);
  });
}
