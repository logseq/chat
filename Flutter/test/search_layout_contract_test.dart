import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Flutter search results list fills the remaining search surface', () {
    final source = File('../lg/logseq_chat/view.cljc').readAsStringSync();
    final searchResultsList = RegExp(
      r'\[:list\s+\{(?=[^}]*:accessibility-identifier\s+"screen\.search\.results")(?=[^}]*:grow\s+1\.0)[^}]*\}',
      multiLine: true,
    );

    expect(source, matches(searchResultsList));
  });
}
