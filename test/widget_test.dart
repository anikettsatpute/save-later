import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:save_later/main.dart';

void main() {
  testWidgets('App boots to inbox empty state', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: SaveLaterApp()));
    await tester.pumpAndSettle();
    expect(find.text('Save Later'), findsOneWidget);
  });
}
