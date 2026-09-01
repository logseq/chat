import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lui_flutter_backend/lui_flutter_backend.dart';

void main() {
  testWidgets('journal virtual list lazily builds offscreen rows', (
    tester,
  ) async {
    final backend = LUIFlutterBackend();
    addTearDown(backend.dispose);
    backend.applyJson(jsonEncode(_journalPatch(rowCount: 100)));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(height: 320, child: backend.widget(node: 1)),
        ),
      ),
    );

    expect(find.byType(ListView), findsOneWidget);
    expect(find.text('Journal row 0'), findsOneWidget);
    expect(find.text('Journal row 99'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Journal row 99'),
      300,
      scrollable: find.byType(Scrollable),
    );

    expect(find.text('Journal row 99'), findsOneWidget);
  });
}

Map<String, Object> _journalPatch({required int rowCount}) {
  final operations = <Map<String, Object>>[
    {'op': 'create-node', 'id': 1, 'kind': 'root'},
    {'op': 'create-node', 'id': 2, 'kind': 'virtual-list'},
    {'op': 'set-prop', 'id': 2, 'property': 'grow', 'value': 1.0},
    {'op': 'insert-child', 'parent': 1, 'child': 2, 'index': 0},
  ];
  for (var index = 0; index < rowCount; index += 1) {
    final id = index + 3;
    operations.addAll([
      {'op': 'create-node', 'id': id, 'kind': 'text'},
      {
        'op': 'set-prop',
        'id': id,
        'property': 'text',
        'value': 'Journal row $index',
      },
      {'op': 'insert-child', 'parent': 2, 'child': id, 'index': index},
    ]);
  }
  return {'generation': 1, 'ops': operations};
}
