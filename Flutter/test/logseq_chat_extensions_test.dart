import 'dart:convert';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/logseq_chat_extensions.dart';
import 'package:logseq_chat_flutter/logseq_chat_theme.dart';
import 'package:lui_flutter_backend/lui_flutter_backend.dart';

void main() {
  testWidgets('resolves relative image assets against Android app storage', (
    tester,
  ) async {
    final backend = LUIFlutterBackend(
      extensionRegistry: logseqChatExtensionRegistry(
        resolveAssetPath: (path) => '/data/user/0/com.logseq.chat/files/$path',
      ),
    );
    addTearDown(backend.dispose);
    final patch = Map<String, Object>.from(_richMarkupPatch);
    patch['ops'] = [
      ...(_richMarkupPatch['ops']! as List<Map<String, Object>>),
      {
        'op': 'set-extension-prop',
        'id': 2,
        'property': 'is-asset',
        'value': true,
      },
      {
        'op': 'set-extension-prop',
        'id': 2,
        'property': 'asset-type',
        'value': 'png',
      },
      {
        'op': 'set-extension-prop',
        'id': 2,
        'property': 'local-path',
        'value': 'Assets/screenshot.png',
      },
    ];
    backend.applyJson(jsonEncode(patch));

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: backend.widget(node: 1))),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(
      (image.image as FileImage).file.path,
      '/data/user/0/com.logseq.chat/files/Assets/screenshot.png',
    );
    final preview = tester.getSemantics(
      find.byKey(const ValueKey('asset.preview.image')),
    );
    expect(preview.identifier, 'asset.preview.image');
  });

  testWidgets('registers and renders every Android Flutter extension', (
    tester,
  ) async {
    final events = <LUIEvent>[];
    final backend = LUIFlutterBackend(
      extensionRegistry: logseqChatExtensionRegistry(),
      onEvent: events.add,
    );
    addTearDown(backend.dispose);

    backend.applyJson(jsonEncode(_extensionPatch));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: backend.widget(node: 1))),
    );

    expect(find.byType(PopScope<Object?>), findsWidgets);
    expect(find.byType(SearchBar), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsOneWidget);
    final overflow = tester.getSemantics(
      find.byKey(const ValueKey('overflow-menu')),
    );
    expect(overflow.identifier, 'button.overflow-menu');
    expect(find.byType(TextField), findsWidgets);
    expect(find.text('Linked page'), findsOneWidget);
  });

  testWidgets('system back reaches the native navigation boundary', (
    tester,
  ) async {
    final events = <LUIEvent>[];
    final backend = LUIFlutterBackend(
      extensionRegistry: logseqChatExtensionRegistry(),
      onEvent: events.add,
    );
    addTearDown(backend.dispose);
    backend.applyJson(jsonEncode(_extensionPatch));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: backend.widget(node: 1))),
    );

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pump();

    expect(
      events,
      contains(
        const LUIEvent.extension(
          node: 5,
          identifier: 'native-navigation-stack',
          name: 'back',
          values: {'count': 1},
        ),
      ),
    );
  });

  testWidgets(
    'repaints when graph picker becomes the journal navigation tree',
    (tester) async {
      final backend = LUIFlutterBackend(
        extensionRegistry: logseqChatExtensionRegistry(),
      );
      addTearDown(backend.dispose);
      backend.applyJson(
        jsonEncode({
          'generation': 1,
          'ops': [
            {'op': 'create-node', 'id': 1, 'kind': 'stack'},
            {'op': 'create-node', 'id': 2, 'kind': 'drawer'},
            {'op': 'set-prop', 'id': 2, 'property': 'selected', 'value': false},
            {'op': 'set-prop', 'id': 2, 'property': 'enabled', 'value': false},
            {
              'op': 'set-prop',
              'id': 2,
              'property': 'toggle-enabled',
              'value': true,
            },
            {'op': 'set-prop', 'id': 2, 'property': 'width', 'value': 360},
            {'op': 'create-node', 'id': 3, 'kind': 'stack'},
            {'op': 'create-node', 'id': 4, 'kind': 'column'},
            {'op': 'create-node', 'id': 5, 'kind': 'text'},
            {
              'op': 'set-prop',
              'id': 5,
              'property': 'text',
              'value': 'Choose a graph',
            },
            {'op': 'insert-child', 'parent': 4, 'child': 5, 'index': 0},
            {'op': 'insert-child', 'parent': 3, 'child': 4, 'index': 0},
            {'op': 'create-node', 'id': 6, 'kind': 'column'},
            {'op': 'insert-child', 'parent': 2, 'child': 3, 'index': 0},
            {'op': 'insert-child', 'parent': 2, 'child': 6, 'index': 1},
            {'op': 'insert-child', 'parent': 1, 'child': 2, 'index': 0},
          ],
        }),
      );
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: backend.widget(node: 1))),
      );
      await tester.pumpAndSettle();
      expect(find.text('Choose a graph'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);

      backend.applyJson(
        jsonEncode({
          'generation': 2,
          'ops': [
            {'op': 'remove-child', 'parent': 3, 'child': 4},
            {'op': 'remove-child', 'parent': 4, 'child': 5},
            {'op': 'drop-node', 'id': 4},
            {
              'op': 'create-extension',
              'id': 263,
              'identifier': 'native-navigation-stack',
              'fingerprint': _navigationFingerprint,
            },
            for (final entry in {
              'depth': 0,
              'bottom-occupies-layout-space': false,
              'composer-dismissal-enabled': false,
              'title': 'Journals',
            }.entries)
              {
                'op': 'set-extension-prop',
                'id': 263,
                'property': entry.key,
                'value': entry.value,
              },
            {'op': 'create-node', 'id': 264, 'kind': 'column'},
            {'op': 'insert-child', 'parent': 263, 'child': 264, 'index': 0},
            {'op': 'create-node', 'id': 265, 'kind': 'text'},
            {
              'op': 'set-prop',
              'id': 265,
              'property': 'text',
              'value': 'Journals',
            },
            {'op': 'insert-child', 'parent': 264, 'child': 265, 'index': 0},
            {'op': 'insert-child', 'parent': 3, 'child': 263, 'index': 0},
            {'op': 'set-prop', 'id': 2, 'property': 'enabled', 'value': true},
          ],
        }),
      );
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pump();

      expect(find.text('Choose a graph'), findsNothing);
      expect(find.text('Journals'), findsOneWidget);
      expect(tester.getSize(find.text('Journals')).height, greaterThan(0));
    },
  );

  testWidgets('overflow menu uses Android action icons', (tester) async {
    final backend = LUIFlutterBackend(
      extensionRegistry: logseqChatExtensionRegistry(),
    );
    addTearDown(backend.dispose);
    backend.applyJson(jsonEncode(_extensionPatch));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: backend.widget(node: 1))),
    );

    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);
    tester
        .state<PopupMenuButtonState<String>>(
          find.byType(PopupMenuButton<String>),
        )
        .showButtonMenu();
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.share_outlined), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);

    await tester.tap(find.text('Favorite'));
    await tester.pumpAndSettle();
    backend.applyJson(
      jsonEncode({
        'generation': 2,
        'ops': [
          {
            'op': 'set-extension-prop',
            'id': 20,
            'property': 'favorite-label',
            'value': 'Unfavorite',
          },
        ],
      }),
    );
    await tester.pump();
    tester
        .state<PopupMenuButtonState<String>>(
          find.byType(PopupMenuButton<String>),
        )
        .showButtonMenu();
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    expect(find.byIcon(Icons.star_outline_rounded), findsNothing);
  });

  testWidgets('editor text changes preserve the caret boundary', (
    tester,
  ) async {
    final events = <LUIEvent>[];
    final backend = LUIFlutterBackend(
      extensionRegistry: logseqChatExtensionRegistry(),
      onEvent: events.add,
    );
    addTearDown(backend.dispose);
    backend.applyJson(jsonEncode(_editorPatch));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: backend.widget(node: 1))),
    );

    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('outliner-editor-a')),
    );
    expect(semantics.identifier, 'field.outliner.block.a');

    await tester.enterText(find.byType(TextField), 'Updated');
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      events,
      contains(
        const LUIEvent.extension(
          node: 2,
          identifier: 'outliner-editor',
          name: 'text-change',
          values: {'title': 'Updated', 'caret-utf16-offset': 7},
        ),
      ),
    );
  });

  testWidgets(
    'editor renders as inline outliner text instead of a form field',
    (tester) async {
      final backend = LUIFlutterBackend(
        extensionRegistry: logseqChatExtensionRegistry(),
      );
      addTearDown(backend.dispose);
      backend.applyJson(jsonEncode(_editorPatch));
      await tester.pumpWidget(
        MaterialApp(
          theme: LogseqChatTheme.light(),
          home: Scaffold(body: backend.widget(node: 1)),
        ),
      );

      final decorator = tester.widget<InputDecorator>(
        find.byType(InputDecorator),
      );
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(decorator.decoration.filled, isFalse);
      expect(decorator.decoration.border, InputBorder.none);
      expect(decorator.decoration.enabledBorder, InputBorder.none);
      expect(decorator.decoration.focusedBorder, InputBorder.none);
      expect(decorator.decoration.contentPadding, EdgeInsets.zero);
      expect(decorator.decoration.isCollapsed, isTrue);
      expect(field.style?.fontSize, 14);
    },
  );

  testWidgets('editor coalesces a rapid text burst before entering LG', (
    tester,
  ) async {
    final events = <LUIEvent>[];
    final backend = LUIFlutterBackend(
      extensionRegistry: logseqChatExtensionRegistry(),
      onEvent: events.add,
    );
    addTearDown(backend.dispose);
    backend.applyJson(jsonEncode(_editorPatch));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: backend.widget(node: 1))),
    );

    final field = find.byType(TextField);
    await tester.enterText(field, 'E');
    await tester.enterText(field, 'E2');
    await tester.enterText(field, 'E2E');

    expect(
      events.where(
        (event) =>
            event is LUIExtensionComponentEvent && event.name == 'text-change',
      ),
      isEmpty,
    );

    await tester.pump(const Duration(milliseconds: 100));
    expect(
      events.where(
        (event) =>
            event is LUIExtensionComponentEvent && event.name == 'text-change',
      ),
      [
        const LUIEvent.extension(
          node: 2,
          identifier: 'outliner-editor',
          name: 'text-change',
          values: {'title': 'E2E', 'caret-utf16-offset': 3},
        ),
      ],
    );
  });

  testWidgets('editor publishes return, caret, and structural backspace', (
    tester,
  ) async {
    final events = <LUIEvent>[];
    final backend = LUIFlutterBackend(
      extensionRegistry: logseqChatExtensionRegistry(),
      onEvent: events.add,
    );
    addTearDown(backend.dispose);
    backend.applyJson(jsonEncode(_editorPatch));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: backend.widget(node: 1))),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Before\n');
    await tester.pump();
    field.controller!.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);

    expect(
      events,
      contains(
        const LUIEvent.extension(
          node: 2,
          identifier: 'outliner-editor',
          name: 'caret-change',
          values: {'caret-utf16-offset': 2},
        ),
      ),
    );
    expect(
      events,
      contains(
        const LUIEvent.extension(
          node: 2,
          identifier: 'outliner-editor',
          name: 'return',
          values: {'title': 'Before', 'caret-utf16-offset': 6},
        ),
      ),
    );
    expect(
      events,
      contains(
        const LUIEvent.extension(
          node: 2,
          identifier: 'outliner-editor',
          name: 'backspace',
          values: {'title': 'Before', 'selection-length': 0},
        ),
      ),
    );
  });

  testWidgets('search uses a Material search bar and publishes queries', (
    tester,
  ) async {
    final events = <LUIEvent>[];
    final backend = LUIFlutterBackend(
      extensionRegistry: logseqChatExtensionRegistry(),
      onEvent: events.add,
    );
    addTearDown(backend.dispose);
    backend.applyJson(jsonEncode(_searchPatch));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: backend.widget(node: 1))),
    );

    final search = tester.getSemantics(
      find.byKey(const ValueKey('search-field')),
    );
    expect(search.identifier, 'field.search');
    expect(
      tester.widget<SearchBar>(find.byType(SearchBar)).hintText,
      'Search pages and blocks',
    );
    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    await tester.enterText(find.byType(SearchBar), 'project');

    expect(
      events,
      contains(
        const LUIEvent.extension(
          node: 2,
          identifier: 'native-search-presentation',
          name: 'query-changed',
          values: {'query': 'project'},
        ),
      ),
    );
  });

  testWidgets('search does not reopen the keyboard for a retained query', (
    tester,
  ) async {
    final backend = LUIFlutterBackend(
      extensionRegistry: logseqChatExtensionRegistry(),
      onEvent: (_) {},
    );
    addTearDown(backend.dispose);
    final patch = Map<String, Object>.from(_searchPatch);
    patch['ops'] = [
      ...(_searchPatch['ops']! as List<Map<String, Object>>),
      {
        'op': 'set-extension-prop',
        'id': 2,
        'property': 'query',
        'value': 'project',
      },
    ];
    backend.applyJson(jsonEncode(patch));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: backend.widget(node: 1))),
    );
    await tester.pump();

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isFalse);
  });

  testWidgets('search releases focus while a result is open', (tester) async {
    final backend = LUIFlutterBackend(
      extensionRegistry: logseqChatExtensionRegistry(),
      onEvent: (_) {},
    );
    addTearDown(backend.dispose);
    backend.applyJson(jsonEncode(_searchPatch));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: backend.widget(node: 1))),
    );
    await tester.pump();
    await tester.enterText(find.byType(SearchBar), 'project');
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );

    backend.applyJson(
      jsonEncode({
        'generation': 2,
        'ops': [
          {
            'op': 'set-extension-prop',
            'id': 2,
            'property': 'depth',
            'value': 1,
          },
        ],
      }),
    );
    await tester.pump();

    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isFalse,
    );
  });

  testWidgets('rich block renders projected markup and opens node links', (
    tester,
  ) async {
    final events = <LUIEvent>[];
    final backend = LUIFlutterBackend(
      extensionRegistry: logseqChatExtensionRegistry(),
      onEvent: events.add,
    );
    addTearDown(backend.dispose);
    final listItemPatch = Map<String, Object>.from(_richMarkupPatch);
    listItemPatch['ops'] = [
      {'op': 'create-node', 'id': 1, 'kind': 'list-item'},
      {'op': 'set-prop', 'id': 1, 'property': 'press-enabled', 'value': true},
      ...(_richMarkupPatch['ops']! as List<Map<String, Object>>).skip(1),
    ];
    backend.applyJson(jsonEncode(listItemPatch));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: backend.widget(node: 1))),
    );

    final blockSemantics = tester.getSemantics(
      find.byKey(const ValueKey('outliner-block-content-block-a')),
    );
    expect(blockSemantics.label, 'Edit block See Project important');
    final inlineSemantics = tester.getSemantics(
      find.byKey(const ValueKey('block.rich.inline.0')),
    );
    expect(inlineSemantics.label, 'See Project important');

    expect(find.text('See '), findsOneWidget);
    expect(find.text('Project'), findsOneWidget);
    expect(find.text('important'), findsOneWidget);

    final nodeLink = tester.getSemantics(
      find.byKey(const ValueKey('link.node.page-a')),
    );
    expect(nodeLink.identifier, 'link.node.page-a');
    expect(nodeLink.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

    tester.semantics.performAction(
      find.semantics.byPredicate(
        (node) => node.getSemanticsData().identifier == 'link.node.page-a',
      ),
      SemanticsAction.tap,
    );
    await tester.pump();

    expect(events, isNot(contains(const LUIEvent.press(node: 1))));
    expect(
      events,
      contains(
        const LUIEvent.extension(
          node: 2,
          identifier: 'outliner-block-content',
          name: 'open-node',
          values: {'uuid': 'page-a'},
        ),
      ),
    );
  });

  testWidgets('rich markup exposes chunk identifiers matching iOS', (
    tester,
  ) async {
    final backend = LUIFlutterBackend(
      extensionRegistry: logseqChatExtensionRegistry(),
    );
    addTearDown(backend.dispose);
    final patch = Map<String, Object>.from(_richMarkupPatch);
    patch['ops'] = [
      ...(_richMarkupPatch['ops']! as List<Map<String, Object>>),
      {
        'op': 'set-extension-prop',
        'id': 2,
        'property': 'markup-json',
        'value': jsonEncode([
          {'type': 'text', 'text': 'Before'},
          {'type': 'video', 'url': 'https://example.com/video.mp4'},
          {'type': 'text', 'text': 'After'},
          {
            'type': 'quote',
            'children': [
              {'type': 'text', 'text': 'Quote'},
            ],
          },
          {'type': 'math', 'text': 'x^2'},
          {'type': 'codeBlock', 'text': 'let x = 1', 'style': 'swift'},
          {'type': 'iframe', 'url': 'https://example.com'},
          {'type': 'youtubeTimestamp', 'text': '01:23', 'style': '83'},
        ]),
      },
    ];
    backend.applyJson(jsonEncode(patch));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: backend.widget(node: 1))),
    );

    for (final identifier in [
      'block.rich.inline.0',
      'block.rich.video',
      'block.rich.inline.2',
      'block.rich.quote',
      'block.rich.math',
      'block.rich.codeBlock',
      'block.rich.iframe',
      'block.rich.youtubeTimestamp',
    ]) {
      final semantics = tester.getSemantics(find.byKey(ValueKey(identifier)));
      expect(semantics.identifier, identifier);
    }
    expect(find.text('swift'), findsOneWidget);
    final highlightedCode = find.descendant(
      of: find.byKey(const ValueKey('block.rich.codeBlock')),
      matching: find.byType(SelectableText),
    );
    expect(highlightedCode, findsOneWidget);
    final selectable = tester.widget<SelectableText>(highlightedCode);
    final colors = <Color>{};
    final rootSpan = selectable.textSpan!;
    void collectColors(InlineSpan span) {
      final color = span.style?.color;
      if (color != null) colors.add(color);
      if (span is TextSpan) {
        for (final child in span.children ?? const <InlineSpan>[]) {
          collectColors(child);
        }
      }
    }

    collectColors(rootSpan);
    expect(colors.length, greaterThan(1));
  });

  testWidgets('youtube timestamp updates its preceding video start', (
    tester,
  ) async {
    final backend = LUIFlutterBackend(
      extensionRegistry: logseqChatExtensionRegistry(),
    );
    addTearDown(backend.dispose);
    backend.applyJson(jsonEncode(_youtubePatch));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: backend.widget(node: 1))),
    );

    expect(find.byKey(const ValueKey('block.rich.video')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('block.rich.youtubeTimestamp')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('block.rich.youtubeTimestamp.start.83')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('block.rich.video.start.83')),
      findsOneWidget,
    );
  });

  testWidgets('long-press drag emits an inside drop on the target block', (
    tester,
  ) async {
    final events = <LUIEvent>[];
    final backend = LUIFlutterBackend(
      extensionRegistry: logseqChatExtensionRegistry(),
      onEvent: events.add,
    );
    addTearDown(backend.dispose);
    backend.applyJson(jsonEncode(_dragPatch));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: backend.widget(node: 1))),
    );

    final source = find.byKey(const ValueKey('outliner-block-content-source'));
    final target = find.byKey(const ValueKey('outliner-block-content-target'));
    final gesture = await tester.startGesture(tester.getCenter(source));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(
      events,
      contains(
        const LUIEvent.extension(
          node: 2,
          identifier: 'outliner-block-content',
          name: 'drag-start',
          values: {'uuid': 'source'},
        ),
      ),
    );
    expect(
      events,
      contains(
        const LUIEvent.extension(
          node: 3,
          identifier: 'outliner-block-content',
          name: 'drop',
          values: {'uuid': 'target', 'placement': 'inside'},
        ),
      ),
    );
  });
}

const _editorFingerprint =
    'lui-extension-v1|15:outliner-editor|profiles:android/flutter,'
    'ios/swiftui,macos/swiftui|standard-children:0|children:|'
    'properties:18:caret-utf16-offset:int:required:none,5:title:string:'
    'required:none,8:block-id:string:required:none|events:11:text-change['
    '18:caret-utf16-offset:int:required,5:title:string:required],12:caret-change['
    '18:caret-utf16-offset:int:required],6:return[18:caret-utf16-offset:int:'
    'required,5:title:string:required],9:backspace[16:selection-length:int:'
    'required,5:title:string:required]';
const _richFingerprint =
    'lui-extension-v1|22:outliner-block-content|profiles:android/flutter,'
    'ios/swiftui,macos/swiftui|standard-children:0|children:|'
    'properties:10:asset-type:string:required:none,10:local-path:string:'
    'required:none,11:markup-json:string:required:none,12:is-completed:bool:'
    'required:none,18:youtube-target-url:string:required:none,5:title:string:'
    'required:none,8:block-id:string:required:none,8:is-asset:bool:required:none|'
    'events:10:drag-start[4:uuid:string:required],4:drop[4:uuid:string:required,'
    '9:placement:string:required],4:edit[4:uuid:string:required],9:open-node['
    '4:uuid:string:required]';
const _navigationFingerprint =
    'lui-extension-v1|23:native-navigation-stack|profiles:android/flutter,'
    'ios/swiftui,macos/swiftui|standard-children:1|children:|'
    'properties:26:composer-dismissal-enabled:bool:required:none,'
    '28:bottom-occupies-layout-space:bool:required:none,5:depth:int:required:none,'
    '5:title:string:required:none|events:16:dismiss-composer[],4:back['
    '5:count:int:required]';
const _searchFingerprint =
    'lui-extension-v1|26:native-search-presentation|profiles:android/flutter,'
    'ios/swiftui,macos/swiftui|standard-children:1|children:|'
    'properties:5:depth:int:required:none,5:query:string:required:none,'
    '5:title:string:required:none,9:presented:bool:required:none|events:'
    '13:query-changed[5:query:string:required],4:back[5:count:int:required],'
    '7:dismiss[]';
const _overflowFingerprint =
    'lui-extension-v1|20:native-overflow-menu|profiles:android/flutter,'
    'ios/swiftui,macos/swiftui|standard-children:0|children:|'
    'properties:14:favorite-label:string:required:none,16:settings-visible:bool:'
    'required:none,20:page-actions-visible:bool:required:none|events:5:share[],'
    '6:delete[],8:favorite[],8:settings[]';

final _editorPatch = {
  'generation': 1,
  'ops': [
    {'op': 'create-node', 'id': 1, 'kind': 'root'},
    {
      'op': 'create-extension',
      'id': 2,
      'identifier': 'outliner-editor',
      'fingerprint': _editorFingerprint,
    },
    {'op': 'set-extension-prop', 'id': 2, 'property': 'block-id', 'value': 'a'},
    {
      'op': 'set-extension-prop',
      'id': 2,
      'property': 'title',
      'value': 'Before',
    },
    {
      'op': 'set-extension-prop',
      'id': 2,
      'property': 'caret-utf16-offset',
      'value': 6,
    },
    {'op': 'insert-child', 'parent': 1, 'child': 2, 'index': 0},
  ],
};

final _searchPatch = {
  'generation': 1,
  'ops': [
    {'op': 'create-node', 'id': 1, 'kind': 'root'},
    {
      'op': 'create-extension',
      'id': 2,
      'identifier': 'native-search-presentation',
      'fingerprint': _searchFingerprint,
    },
    {
      'op': 'set-extension-prop',
      'id': 2,
      'property': 'presented',
      'value': true,
    },
    {'op': 'set-extension-prop', 'id': 2, 'property': 'depth', 'value': 0},
    {'op': 'set-extension-prop', 'id': 2, 'property': 'query', 'value': ''},
    {
      'op': 'set-extension-prop',
      'id': 2,
      'property': 'title',
      'value': 'Search',
    },
    {'op': 'create-node', 'id': 3, 'kind': 'text'},
    {'op': 'set-prop', 'id': 3, 'property': 'text', 'value': 'Results'},
    {'op': 'insert-child', 'parent': 2, 'child': 3, 'index': 0},
    {'op': 'insert-child', 'parent': 1, 'child': 2, 'index': 0},
  ],
};

final _richMarkupPatch = {
  'generation': 1,
  'ops': [
    {'op': 'create-node', 'id': 1, 'kind': 'root'},
    {
      'op': 'create-extension',
      'id': 2,
      'identifier': 'outliner-block-content',
      'fingerprint': _richFingerprint,
    },
    for (final entry in {
      'block-id': 'block-a',
      'title': 'See Project important',
      'markup-json': jsonEncode([
        {'type': 'text', 'text': 'See '},
        {'type': 'nodeReference', 'uuid': 'page-a', 'title': 'Project'},
        {'type': 'text', 'text': ' '},
        {'type': 'code', 'text': 'important'},
      ]),
      'youtube-target-url': '',
      'is-asset': false,
      'is-completed': true,
      'asset-type': '',
      'local-path': '',
    }.entries)
      {
        'op': 'set-extension-prop',
        'id': 2,
        'property': entry.key,
        'value': entry.value,
      },
    {'op': 'insert-child', 'parent': 1, 'child': 2, 'index': 0},
  ],
};

final _extensionPatch = {
  'generation': 1,
  'ops': [
    {'op': 'create-node', 'id': 1, 'kind': 'root'},
    {'op': 'create-node', 'id': 30, 'kind': 'stack'},
    {'op': 'set-prop', 'id': 30, 'property': 'grow', 'value': 1.0},
    ...(_editorPatch['ops']! as List<Map<String, Object>>).skip(1).take(4),
    {
      'op': 'create-extension',
      'id': 4,
      'identifier': 'outliner-block-content',
      'fingerprint': _richFingerprint,
    },
    for (final entry in {
      'block-id': 'b',
      'title': 'Linked page',
      'markup-json': '[]',
      'youtube-target-url': '',
      'is-asset': false,
      'is-completed': false,
      'asset-type': '',
      'local-path': '',
    }.entries)
      {
        'op': 'set-extension-prop',
        'id': 4,
        'property': entry.key,
        'value': entry.value,
      },
    {
      'op': 'create-extension',
      'id': 5,
      'identifier': 'native-navigation-stack',
      'fingerprint': _navigationFingerprint,
    },
    for (final entry in {
      'depth': 1,
      'bottom-occupies-layout-space': false,
      'composer-dismissal-enabled': false,
      'title': 'Journal',
    }.entries)
      {
        'op': 'set-extension-prop',
        'id': 5,
        'property': entry.key,
        'value': entry.value,
      },
    {'op': 'create-node', 'id': 6, 'kind': 'text'},
    {'op': 'set-prop', 'id': 6, 'property': 'text', 'value': 'Navigation'},
    {'op': 'insert-child', 'parent': 5, 'child': 6, 'index': 0},
    ...(_searchPatch['ops']! as List<Map<String, Object>>)
        .skip(1)
        .take(6)
        .map(
          (operation) => operation.map(
            (key, value) => MapEntry(key, value is int ? value + 10 : value),
          ),
        ),
    {
      'op': 'create-extension',
      'id': 20,
      'identifier': 'native-overflow-menu',
      'fingerprint': _overflowFingerprint,
    },
    for (final entry in {
      'page-actions-visible': true,
      'favorite-label': 'Favorite',
      'settings-visible': true,
    }.entries)
      {
        'op': 'set-extension-prop',
        'id': 20,
        'property': entry.key,
        'value': entry.value,
      },
    for (final id in [2, 4, 5, 12, 20])
      {'op': 'insert-child', 'parent': 30, 'child': id, 'index': 0},
    {'op': 'insert-child', 'parent': 1, 'child': 30, 'index': 0},
  ],
};

final _youtubePatch = {
  'generation': 1,
  'ops': [
    {'op': 'create-node', 'id': 1, 'kind': 'column'},
    for (final entry in [
      (
        id: 2,
        blockId: 'video',
        title: 'Video',
        markup: [
          {
            'type': 'video',
            'url': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          },
        ],
        target: '',
      ),
      (
        id: 3,
        blockId: 'timestamp',
        title: 'Timestamp',
        markup: [
          {'type': 'youtubeTimestamp', 'text': '01:23', 'style': '83'},
        ],
        target: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      ),
    ]) ...[
      {
        'op': 'create-extension',
        'id': entry.id,
        'identifier': 'outliner-block-content',
        'fingerprint': _richFingerprint,
      },
      for (final property in {
        'block-id': entry.blockId,
        'title': entry.title,
        'markup-json': jsonEncode(entry.markup),
        'youtube-target-url': entry.target,
        'is-asset': false,
        'is-completed': false,
        'asset-type': '',
        'local-path': '',
      }.entries)
        {
          'op': 'set-extension-prop',
          'id': entry.id,
          'property': property.key,
          'value': property.value,
        },
      {
        'op': 'insert-child',
        'parent': 1,
        'child': entry.id,
        'index': entry.id - 2,
      },
    ],
  ],
};

final _dragPatch = {
  'generation': 1,
  'ops': [
    {'op': 'create-node', 'id': 1, 'kind': 'column'},
    for (final entry in [(id: 2, uuid: 'source'), (id: 3, uuid: 'target')]) ...[
      {
        'op': 'create-extension',
        'id': entry.id,
        'identifier': 'outliner-block-content',
        'fingerprint': _richFingerprint,
      },
      for (final property in {
        'block-id': entry.uuid,
        'title': entry.uuid,
        'markup-json': '[]',
        'youtube-target-url': '',
        'is-asset': false,
        'is-completed': false,
        'asset-type': '',
        'local-path': '',
      }.entries)
        {
          'op': 'set-extension-prop',
          'id': entry.id,
          'property': property.key,
          'value': property.value,
        },
      {
        'op': 'insert-child',
        'parent': 1,
        'child': entry.id,
        'index': entry.id - 2,
      },
    ],
  ],
};
