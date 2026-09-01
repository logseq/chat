import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/flutter_patch_applier.dart';
import 'package:logseq_chat_flutter/logseq_chat_icons.dart';
import 'package:logseq_chat_flutter/logseq_chat_theme.dart';
import 'package:lui_flutter_backend/lui_flutter_backend.dart';

void main() {
  test('applies consecutive Settings and Add graph sheets', () {
    final backend = LUIFlutterBackend();
    final applier = FlutterPatchApplier(backend);

    applier.applyJson(
      _patch(1, [
        _createNode(1, 'sheet'),
        _setProperty(1, 'text', 'Settings'),
        _setProperty(1, 'style-class', 'navigation-scroll'),
      ]),
    );
    applier.applyJson(
      _patch(2, [
        _createNode(2, 'sheet'),
        _setProperty(2, 'text', 'Add sync graph'),
        _setProperty(2, 'style-class', 'navigation-form'),
      ]),
    );

    expect(backend.generation, 2);
    expect(backend.containsNode(1), isTrue);
    expect(backend.containsNode(2), isTrue);
  });

  test('notifies the host only when a mounted structure changes', () {
    final backend = LUIFlutterBackend();
    final applier = FlutterPatchApplier(backend);
    applier.applyJson(
      _patch(1, [
        _createNode(1, 'stack'),
        _createNode(2, 'text'),
        _setProperty(2, 'text', 'Before'),
        _insertChild(1, 2, 0),
      ]),
    );
    var notifications = 0;
    applier.addListener(() => notifications += 1);

    applier.applyJson(_patch(2, [_setProperty(2, 'text', 'Updated')]));

    expect(notifications, 0);

    applier.applyJson(
      _patch(3, [
        _createNode(3, 'text'),
        _setProperty(3, 'text', 'After'),
        _insertChild(1, 3, 0),
        _removeChild(1, 2),
        _dropNode(2),
      ]),
    );

    expect(notifications, 1);
  });

  for (final sheet in const [
    (title: 'Settings', styleClass: 'navigation-scroll'),
    (title: 'Add sync graph', styleClass: 'navigation-form'),
  ]) {
    testWidgets('renders the ${sheet.title} bottom sheet', (tester) async {
      final backend = LUIFlutterBackend();
      final applier = FlutterPatchApplier(backend);
      final operations = <Map<String, Object>>[
        _createNode(1, 'sheet'),
        _setProperty(1, 'text', sheet.title),
        _setProperty(1, 'style-class', sheet.styleClass),
      ];
      if (sheet.title == 'Settings') {
        operations.addAll([
          _setProperty(1, 'height', 640),
          _createNode(2, 'column'),
          _setProperty(2, 'grow', 1.0),
          _createNode(5, 'scroll'),
          _setProperty(5, 'grow', 1.0),
          _createNode(6, 'column'),
          for (var id = 10; id < 50; id++) ...[
            _createNode(id, 'text'),
            _setProperty(id, 'text', 'Settings row $id'),
            _insertChild(6, id, id - 10),
          ],
          _insertChild(5, 6, 0),
          _insertChild(2, 5, 0),
          _createNode(3, 'toolbar'),
          _setProperty(3, 'accessibility-label', 'Settings actions'),
          _createNode(4, 'button'),
          _setProperty(4, 'text', 'Apply'),
          _insertChild(3, 4, 0),
          _insertChild(2, 3, 1),
          _insertChild(1, 2, 0),
        ]);
      }

      applier.applyJson(_patch(1, operations));
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: backend.widget(node: 1))),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('lui-sheet-surface-1')), findsOneWidget);
      expect(find.text(sheet.title), findsOneWidget);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('lui-sheet-surface-1')))
            .height,
        greaterThan(0),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('renders Material navigation chrome at standard size', (
    tester,
  ) async {
    final backend = LUIFlutterBackend(appIcons: logseqChatAppIcons);
    final applier = FlutterPatchApplier(backend);
    applier.applyJson(
      _patch(1, [
        _createNode(1, 'row'),
        _createNode(2, 'button'),
        _setProperty(2, 'icon', 'app:sidebar-toggle'),
        _setProperty(2, 'size', 'icon'),
        _setProperty(2, 'variant', 'ghost'),
        _setProperty(2, 'accessibility-label', 'Open sidebar'),
        _createNode(3, 'heading'),
        _setProperty(3, 'text', 'Journals'),
        _setProperty(3, 'heading-level', 3),
        _insertChild(1, 2, 0),
        _insertChild(1, 3, 1),
      ]),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: LogseqChatTheme.light(),
        home: Scaffold(body: Center(child: backend.widget(node: 1))),
      ),
    );

    final icon = tester.widget<Icon>(find.byIcon(Icons.menu_rounded));
    final button = find.byType(TextButton);
    final buttonWidget = tester.widget<TextButton>(button);
    final title = tester.widget<Text>(find.text('Journals'));
    expect(icon.size, 24);
    expect(
      buttonWidget.style?.minimumSize?.resolve(<WidgetState>{}),
      const Size.square(48),
    );
    expect(title.style?.fontSize, 22);
  });

  test('keeps generation continuous when an ignored property is removed', () {
    final backend = LUIFlutterBackend();
    final applier = FlutterPatchApplier(backend);

    applier.applyJson(
      _patch(1, [
        _createNode(1, 'dialog'),
        _setProperty(1, 'text', 'Delete page'),
        _setProperty(1, 'style-class', 'alert'),
      ]),
    );
    applier.applyJson(_patch(2, [_removeProperty(1, 'style-class')]));

    expect(backend.generation, 2);
  });

  test('drops SwiftUI container sizing hints', () {
    final backend = LUIFlutterBackend();
    final applier = FlutterPatchApplier(backend);

    applier.applyJson(
      _patch(1, [
        _createNode(1, 'column'),
        _setProperty(1, 'container-relative-frame', 'vertical'),
        _setProperty(1, 'container-relative-frame-inset', 136),
      ]),
    );

    expect(backend.generation, 1);
    expect(backend.containsNode(1), isTrue);
  });

  test('drops unsupported list and top icon presentation hints', () {
    final backend = LUIFlutterBackend();
    final applier = FlutterPatchApplier(backend);

    applier.applyJson(
      _patch(1, [
        _createNode(1, 'list-item'),
        _setProperty(1, 'text', 'Journals'),
        _setProperty(1, 'role', 'navigation'),
        _setProperty(1, 'icon-placement', 'trailing'),
        _createNode(2, 'button'),
        _setProperty(2, 'text', 'Copy'),
        _setProperty(2, 'icon-placement', 'top'),
      ]),
    );

    expect(backend.generation, 1);
  });

  test('preserves supported context menu presentation metadata', () {
    final backend = LUIFlutterBackend();
    final applier = FlutterPatchApplier(backend);

    applier.applyJson(
      _patch(1, [
        _createNode(1, 'list-item'),
        _setProperty(1, 'text', 'Graph'),
        _setProperty(1, 'press-enabled', true),
        _createNode(2, 'context-menu'),
        _createNode(3, 'menu-item'),
        _setProperty(3, 'text', 'Delete local graph'),
        _setProperty(3, 'icon', 'trash'),
        _setProperty(3, 'foreground', 'destructive'),
        _setProperty(3, 'press-enabled', true),
        _setProperty(3, 'enabled', true),
        _insertChild(2, 3, 0),
        _insertChild(1, 2, 0),
      ]),
    );

    expect(backend.generation, 1);
    expect(backend.containsNode(3), isTrue);
  });

  test('drops the SwiftUI retained-pane selection hint from virtual lists', () {
    final backend = LUIFlutterBackend();
    final applier = FlutterPatchApplier(backend);

    applier.applyJson(
      _patch(1, [
        _createNode(1, 'virtual-list'),
        _setProperty(1, 'selected', true),
      ]),
    );

    expect(backend.generation, 1);
    expect(backend.containsNode(1), isTrue);
  });

  test(
    'drops axis-specific padding from controls that only support total padding',
    () {
      final backend = LUIFlutterBackend();
      final applier = FlutterPatchApplier(backend);

      applier.applyJson(
        _patch(1, [
          _createNode(1, 'button'),
          _setProperty(1, 'text', 'Capture'),
          _setProperty(1, 'padding-horizontal', 8),
        ]),
      );

      expect(backend.generation, 1);
      expect(backend.containsNode(1), isTrue);
    },
  );

  test('preserves Flutter-supported presentation properties', () {
    final backend = LUIFlutterBackend();
    final applier = FlutterPatchApplier(backend);

    applier.applyJson(
      _patch(1, [
        _createNode(1, 'toolbar'),
        _setProperty(1, 'accessibility-label', 'Actions'),
        _setProperty(1, 'style-class', 'navigation-actions'),
        _createNode(2, 'button'),
        _setProperty(2, 'text', 'Continue'),
        _setProperty(2, 'icon-placement', 'trailing'),
      ]),
    );

    expect(backend.generation, 1);
  });

  test('does not hide unsupported behavioral properties', () {
    final backend = LUIFlutterBackend();
    final applier = FlutterPatchApplier(backend);

    expect(
      () => applier.applyJson(
        _patch(1, [_createNode(1, 'text'), _setProperty(1, 'enabled', true)]),
      ),
      throwsA(isA<LUIBackendException>()),
    );
    expect(backend.generation, 0);
    expect(backend.containsNode(1), isFalse);
  });
}

String _patch(int generation, List<Map<String, Object>> operations) =>
    jsonEncode({'generation': generation, 'ops': operations});

Map<String, Object> _createNode(int id, String kind) => {
  'op': 'create-node',
  'id': id,
  'kind': kind,
};

Map<String, Object> _setProperty(int id, String property, Object value) => {
  'op': 'set-prop',
  'id': id,
  'property': property,
  'value': value,
};

Map<String, Object> _removeProperty(int id, String property) => {
  'op': 'remove-prop',
  'id': id,
  'property': property,
};

Map<String, Object> _insertChild(int parent, int child, int index) => {
  'op': 'insert-child',
  'parent': parent,
  'child': child,
  'index': index,
};

Map<String, Object> _removeChild(int parent, int child) => {
  'op': 'remove-child',
  'parent': parent,
  'child': child,
};

Map<String, Object> _dropNode(int id) => {'op': 'drop-node', 'id': id};
