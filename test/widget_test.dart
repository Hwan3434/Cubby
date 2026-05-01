import 'package:flutter_test/flutter_test.dart';

import 'package:cubby/main.dart';

void main() {
  testWidgets('Cubby app renders', (WidgetTester tester) async {
    await tester.pumpWidget(const CubbyApp());
    expect(find.text('Cubby'), findsOneWidget);
  });
}
