import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/android_math.dart';

void main() {
  testWidgets('renders TeX as an accessible native Flutter equation', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AndroidMath(expression: r'\frac{1}{2}')),
      ),
    );

    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('math.rendered')),
    );
    expect(semantics.identifier, 'block.rich.math.rendered');
    expect(semantics.label, r'Math: \frac{1}{2}');
    expect(find.text(r'\frac{1}{2}'), findsNothing);
  });

  testWidgets('falls back to readable source when TeX is invalid', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AndroidMath(expression: r'\definitelyUnknown{')),
      ),
    );

    expect(find.text(r'\definitelyUnknown{'), findsOneWidget);
  });
}
