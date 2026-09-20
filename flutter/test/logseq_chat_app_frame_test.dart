import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/logseq_chat_app_frame.dart';

void main() {
  testWidgets('keeps app content outside Android system bars', (tester) async {
    const systemPadding = EdgeInsets.only(top: 48, bottom: 24);

    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(padding: systemPadding),
          child: LogseqChatAppFrame(
            child: SizedBox.expand(key: ValueKey('content')),
          ),
        ),
      ),
    );

    final content = tester.getRect(find.byKey(const ValueKey('content')));
    expect(content.top, systemPadding.top);
    expect(content.bottom, 600 - systemPadding.bottom);
  });
}
