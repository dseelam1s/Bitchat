import 'package:flutter_test/flutter_test.dart';

import 'package:bitchat_messenger/main.dart';

void main() {
  testWidgets('App initializes', (WidgetTester tester) async {
    await tester.pumpWidget(const BitChatApp());
    expect(find.text('Initializing BitChat...'), findsOneWidget);
  });
}
