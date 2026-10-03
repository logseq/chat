import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _viewSource() {
  final directory = Directory('../shared/src/logseq_chat');
  final files = directory
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.ml'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return files.map((file) => file.readAsStringSync()).join('\n');
}

void main() {
  test('Flutter search results list fills the remaining search surface', () {
    final source = _viewSource();
    final searchResultsList = RegExp(
      r'\blist\b(?=[\s\S]{0,200}~accessibility_identifier:\s*"screen\.search\.results")(?=[\s\S]{0,200}~grow:\s*1\.0)',
      multiLine: true,
    );

    expect(source, matches(searchResultsList));
  });
}
