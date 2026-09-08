import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/flutter_patch_applier.dart';
import 'package:logseq_chat_flutter/logseq_chat_icons.dart';
import 'package:logseq_chat_flutter/logseq_chat_theme.dart';
import 'package:lui_flutter_backend/lui_flutter_backend.dart';

void main() {
  for (final direction in TextDirection.values) {
    testWidgets(
      'search icon is centered in its entire touch target ($direction)',
      (tester) async {
        final backend = LUIFlutterBackend(appIcons: logseqChatAppIcons);
        addTearDown(backend.dispose);
        FlutterPatchApplier(backend).applyJson(
          jsonEncode({
            'generation': 1,
            'ops': [
              {'op': 'create-node', 'id': 1, 'kind': 'button'},
              for (final property in <String, Object>{
                'icon': 'app:search',
                'size': 'icon',
                'variant': 'secondary',
                'width': 58,
                'height': 58,
                'accessibility-label': 'Search',
              }.entries)
                {
                  'op': 'set-prop',
                  'id': 1,
                  'property': property.key,
                  'value': property.value,
                },
            ],
          }),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: LogseqChatTheme.light(),
            home: Scaffold(
              body: Directionality(
                textDirection: direction,
                child: Center(child: backend.widget(node: 1)),
              ),
            ),
          ),
        );
        expect(
          tester.getCenter(find.byIcon(Icons.search_rounded)),
          tester.getCenter(find.byType(FilledButton)),
        );
      },
    );
  }
}
