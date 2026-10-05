import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/main.dart';

void main() {
  testWidgets('JarvisApp starts and shows the placeholder screen', (
    tester,
  ) async {
    await tester.pumpWidget(const JarvisApp());

    expect(find.text('Jarvis'), findsOneWidget);
    expect(find.text('Voice-first personal AI assistant'), findsOneWidget);
  });
}
