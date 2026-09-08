import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/graph_catalog_polling_policy.dart';

void main() {
  test('polls only while an authenticated graph picker is foreground', () {
    expect(
      shouldPollGraphCatalog(
        authenticated: true,
        hasOpenGraph: false,
        foreground: true,
      ),
      isTrue,
    );
    expect(
      shouldPollGraphCatalog(
        authenticated: true,
        hasOpenGraph: true,
        foreground: true,
      ),
      isFalse,
    );
    expect(
      shouldPollGraphCatalog(
        authenticated: true,
        hasOpenGraph: false,
        foreground: false,
      ),
      isFalse,
    );
  });
}
