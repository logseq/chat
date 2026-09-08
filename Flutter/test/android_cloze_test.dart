import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/android_cloze.dart';

void main() {
  testWidgets('reveals and hides cloze content with Material semantics', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AndroidCloze(text: 'Paris')),
      ),
    );

    final finder = find.byKey(const ValueKey('button.cloze.reveal'));
    expect(find.text('Tap to reveal'), findsOneWidget);
    expect(find.text('Paris'), findsNothing);

    await tester.tap(finder);
    await tester.pump();
    expect(find.text('Paris'), findsOneWidget);

    await tester.tap(finder);
    await tester.pump();
    expect(find.text('Tap to reveal'), findsOneWidget);
  });
}
