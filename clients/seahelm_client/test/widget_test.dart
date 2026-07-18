import 'package:flutter_test/flutter_test.dart';

import 'package:seahelm_client/main.dart';

void main() {
  testWidgets('app boots to connect screen', (WidgetTester tester) async {
    await tester.pumpWidget(const SeahelmApp());
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('SRP endpoint'), findsOneWidget);
  });
}
