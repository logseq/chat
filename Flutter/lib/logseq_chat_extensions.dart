import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:highlighter/highlighter.dart' as syntax;
import 'package:lui_flutter_backend/lui_flutter_backend.dart';

import 'android_audio_playback.dart';
import 'android_cloze.dart';
import 'android_embedded_media.dart';
import 'android_math.dart';

final _syntaxNodeCache = <String, List<syntax.Node>>{};
const _syntaxNodeCacheLimit = 64;

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

String _identityAssetPath(String path) => path;

LUIFlutterExtensionRegistry logseqChatExtensionRegistry({
  String Function(String) resolveAssetPath = _identityAssetPath,
}) {
  final youtubePlayback = _YoutubePlaybackCoordinator();
  return LUIFlutterExtensionRegistry()
    ..register(
      LUIFlutterExtension(
        identifier: 'outliner-editor',
        fingerprint: _editorFingerprint,
        properties: [
          _requiredStringProperty('block-id'),
          _requiredStringProperty('title'),
          _requiredIntProperty('caret-utf16-offset'),
        ],
        events: [
          LUIExtensionEventSchema(
            name: 'text-change',
            fields: [
              _requiredStringField('title'),
              _requiredIntField('caret-utf16-offset'),
            ],
          ),
          LUIExtensionEventSchema(
            name: 'return',
            fields: [
              _requiredStringField('title'),
              _requiredIntField('caret-utf16-offset'),
            ],
          ),
          LUIExtensionEventSchema(
            name: 'backspace',
            fields: [
              _requiredStringField('title'),
              _requiredIntField('selection-length'),
            ],
          ),
          LUIExtensionEventSchema(
            name: 'caret-change',
            fields: [_requiredIntField('caret-utf16-offset')],
          ),
        ],
        builder: (context) => _OutlinerEditor(context: context),
      ),
    )
    ..register(
      LUIFlutterExtension(
        identifier: 'outliner-block-content',
        fingerprint: _richFingerprint,
        properties: [
          _requiredStringProperty('title'),
          _requiredStringProperty('block-id'),
          _requiredStringProperty('markup-json'),
          _requiredStringProperty('youtube-target-url'),
          _requiredBoolProperty('is-asset'),
          _requiredBoolProperty('is-completed'),
          _requiredStringProperty('asset-type'),
          _requiredStringProperty('local-path'),
        ],
        events: [
          LUIExtensionEventSchema(
            name: 'drag-start',
            fields: [_requiredStringField('uuid')],
          ),
          LUIExtensionEventSchema(
            name: 'drop',
            fields: [
              _requiredStringField('uuid'),
              _requiredStringField('placement'),
            ],
          ),
          LUIExtensionEventSchema(
            name: 'edit',
            fields: [_requiredStringField('uuid')],
          ),
          LUIExtensionEventSchema(
            name: 'open-node',
            fields: [_requiredStringField('uuid')],
          ),
        ],
        builder: (context) => _OutlinerBlockContent(
          context: context,
          youtubePlayback: youtubePlayback,
          resolveAssetPath: resolveAssetPath,
        ),
      ),
    )
    ..register(
      LUIFlutterExtension(
        identifier: 'native-navigation-stack',
        fingerprint: _navigationFingerprint,
        acceptsStandardChildren: true,
        properties: [
          _requiredIntProperty('depth'),
          _requiredBoolProperty('bottom-occupies-layout-space'),
          _requiredBoolProperty('composer-dismissal-enabled'),
          _requiredStringProperty('title'),
        ],
        events: [
          LUIExtensionEventSchema(
            name: 'back',
            fields: [_requiredIntField('count')],
          ),
          LUIExtensionEventSchema(name: 'dismiss-composer'),
        ],
        builder: (context) => _NavigationBoundary(context: context),
      ),
    )
    ..register(
      LUIFlutterExtension(
        identifier: 'native-search-presentation',
        fingerprint: _searchFingerprint,
        acceptsStandardChildren: true,
        properties: [
          _requiredBoolProperty('presented'),
          _requiredIntProperty('depth'),
          _requiredStringProperty('query'),
          _requiredStringProperty('title'),
        ],
        events: [
          LUIExtensionEventSchema(
            name: 'back',
            fields: [_requiredIntField('count')],
          ),
          LUIExtensionEventSchema(name: 'dismiss'),
          LUIExtensionEventSchema(
            name: 'query-changed',
            fields: [_requiredStringField('query')],
          ),
        ],
        builder: (context) => _SearchPresentation(context: context),
      ),
    )
    ..register(
      LUIFlutterExtension(
        identifier: 'native-overflow-menu',
        fingerprint: _overflowFingerprint,
        properties: [
          _requiredBoolProperty('page-actions-visible'),
          _requiredStringProperty('favorite-label'),
          _requiredBoolProperty('settings-visible'),
        ],
        events: [
          LUIExtensionEventSchema(name: 'favorite'),
          LUIExtensionEventSchema(name: 'share'),
          LUIExtensionEventSchema(name: 'delete'),
          LUIExtensionEventSchema(name: 'settings'),
        ],
        builder: (context) => _OverflowMenu(context: context),
      ),
    );
}

LUIExtensionEventField _requiredStringField(String name) =>
    LUIExtensionEventField(
      name: name,
      kind: LUIExtensionValueKind.string,
      isRequired: true,
    );

LUIExtensionEventField _requiredIntField(String name) => LUIExtensionEventField(
  name: name,
  kind: LUIExtensionValueKind.integer,
  isRequired: true,
);

LUIExtensionProperty _requiredStringProperty(String name) =>
    LUIExtensionProperty(
      name: name,
      kind: LUIExtensionValueKind.string,
      isRequired: true,
    );

LUIExtensionProperty _requiredBoolProperty(String name) => LUIExtensionProperty(
  name: name,
  kind: LUIExtensionValueKind.boolean,
  isRequired: true,
);

LUIExtensionProperty _requiredIntProperty(String name) => LUIExtensionProperty(
  name: name,
  kind: LUIExtensionValueKind.integer,
  isRequired: true,
);

final class _NavigationBoundary extends StatelessWidget {
  const _NavigationBoundary({required this.context});

  final LUIFlutterExtensionContext context;

  @override
  Widget build(BuildContext buildContext) {
    final depth = context.property('depth')! as int;
    final dismissesComposer =
        context.property('composer-dismissal-enabled')! as bool;
    return PopScope<Object?>(
      canPop: depth == 0 && !dismissesComposer,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (dismissesComposer) {
          context.emit(name: 'dismiss-composer');
        } else if (depth > 0) {
          context.emit(name: 'back', values: const {'count': 1});
        }
      },
      child: context.content,
    );
  }
}

final class _SearchPresentation extends StatefulWidget {
  const _SearchPresentation({required this.context});

  final LUIFlutterExtensionContext context;

  @override
  State<_SearchPresentation> createState() => _SearchPresentationState();
}

final class _SearchPresentationState extends State<_SearchPresentation>
    with SingleTickerProviderStateMixin {
  late final SearchController _controller;
  late final FocusNode _focusNode;
  late final AnimationController _transition;
  late String _modelQuery;
  late bool _presented;
  var _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = SearchController();
    _focusNode = FocusNode();
    _modelQuery = widget.context.property('query')! as String;
    _controller.text = _modelQuery;
    _presented = widget.context.property('presented')! as bool;
    _transition = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    );
    if (_presented) _transition.forward();
  }

  @override
  void didUpdateWidget(covariant _SearchPresentation oldWidget) {
    super.didUpdateWidget(oldWidget);
    final query = widget.context.property('query')! as String;
    if (query != _modelQuery) {
      _modelQuery = query;
      if (_controller.text != query) {
        _controller.value = TextEditingValue(
          text: query,
          selection: TextSelection.collapsed(offset: query.length),
        );
      }
    }
    final presented = widget.context.property('presented')! as bool;
    if (presented != _presented) {
      _presented = presented;
      _closing = false;
      if (presented) {
        _transition.forward(from: 0);
      } else {
        _transition.value = 0;
        _focusNode.unfocus();
      }
    }
    if ((widget.context.property('depth')! as int) > 0) {
      _focusNode.unfocus();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _transition.duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 160);
  }

  Future<void> _dismiss() async {
    if (_closing) return;
    _closing = true;
    _focusNode.unfocus();
    try {
      await _transition.reverse().orCancel;
      if (mounted && _presented) widget.context.emit(name: 'dismiss');
    } on TickerCanceled {
      // The host may close or replace search while its transition is running.
    }
  }

  @override
  Widget build(BuildContext context) {
    final extension = widget.context;
    if (!(extension.property('presented')! as bool)) return extension.content;
    final depth = extension.property('depth')! as int;
    final query = extension.property('query')! as String;
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (depth > 0) {
          extension.emit(name: 'back', values: const {'count': 1});
        } else {
          unawaited(_dismiss());
        }
      },
      child: FadeTransition(
        opacity: _transition,
        alwaysIncludeSemantics: true,
        child: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Semantics(
                  key: const ValueKey('search-field'),
                  identifier: 'field.search',
                  child: SearchBar(
                    controller: _controller,
                    focusNode: _focusNode,
                    autoFocus: query.isEmpty,
                    hintText: 'Search pages and blocks',
                    leading: IconButton(
                      tooltip: depth > 0 ? 'Back' : 'Close search',
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: () {
                        if (depth > 0) {
                          extension.emit(
                            name: 'back',
                            values: const {'count': 1},
                          );
                        } else {
                          unawaited(_dismiss());
                        }
                      },
                    ),
                    trailing: [
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _controller,
                        builder: (context, value, _) => value.text.isEmpty
                            ? const SizedBox.shrink()
                            : IconButton(
                                tooltip: 'Clear search',
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () {
                                  _controller.clear();
                                  extension.emit(
                                    name: 'query-changed',
                                    values: const {'query': ''},
                                  );
                                  _focusNode.requestFocus();
                                },
                              ),
                      ),
                    ],
                    onChanged: (query) => extension.emit(
                      name: 'query-changed',
                      values: {'query': query},
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: NotificationListener<ScrollStartNotification>(
                onNotification: (notification) {
                  if (notification.dragDetails != null) _focusNode.unfocus();
                  return false;
                },
                child: extension.content,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _transition.dispose();
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }
}

final class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({required this.context});

  final LUIFlutterExtensionContext context;

  @override
  Widget build(BuildContext buildContext) {
    final pageActions = context.property('page-actions-visible')! as bool;
    final settings = context.property('settings-visible')! as bool;
    return Semantics(
      key: const ValueKey('overflow-menu'),
      identifier: 'button.overflow-menu',
      button: true,
      child: PopupMenuButton<String>(
        tooltip: 'More',
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: (name) => context.emit(name: name),
        itemBuilder: (_) => [
          if (pageActions) ...[
            PopupMenuItem(
              value: 'favorite',
              child: _MenuAction(
                icon:
                    (context.property('favorite-label')! as String) ==
                        'Unfavorite'
                    ? Icons.star_rounded
                    : Icons.star_outline_rounded,
                label: context.property('favorite-label')! as String,
              ),
            ),
            const PopupMenuItem(
              value: 'share',
              child: _MenuAction(icon: Icons.share_outlined, label: 'Share'),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: _MenuAction(
                icon: Icons.delete_outline_rounded,
                label: 'Delete',
              ),
            ),
          ],
          if (settings)
            const PopupMenuItem(
              value: 'settings',
              child: _MenuAction(
                icon: Icons.settings_outlined,
                label: 'Settings',
              ),
            ),
        ],
      ),
    );
  }
}

final class _MenuAction extends StatelessWidget {
  const _MenuAction({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)],
  );
}

final class _YoutubePlaybackCoordinator
    extends ValueNotifier<Map<String, int>> {
  _YoutubePlaybackCoordinator() : super(const {});

  void seek(String url, int seconds) {
    if (url.isEmpty) return;
    value = {...value, url: seconds};
  }
}

final class _OutlinerBlockContent extends StatelessWidget {
  const _OutlinerBlockContent({
    required this.context,
    required this.youtubePlayback,
    required this.resolveAssetPath,
  });

  final LUIFlutterExtensionContext context;
  final _YoutubePlaybackCoordinator youtubePlayback;
  final String Function(String) resolveAssetPath;

  @override
  Widget build(BuildContext buildContext) {
    final uuid = context.property('block-id')! as String;
    final title = context.property('title')! as String;
    final completed = context.property('is-completed')! as bool;
    final isAsset = context.property('is-asset')! as bool;
    final row = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.emit(name: 'edit', values: {'uuid': uuid}),
      child: DefaultTextStyle.merge(
        style: completed
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
        child: isAsset
            ? _ProjectedAsset(
                title: title,
                assetType: context.property('asset-type')! as String,
                localPath: resolveAssetPath(
                  context.property('local-path')! as String,
                ),
              )
            : _ProjectedMarkup(
                encoded: context.property('markup-json')! as String,
                fallback: title,
                youtubeTargetUrl:
                    context.property('youtube-target-url')! as String,
                youtubePlayback: youtubePlayback,
                onOpenNode: (nodeUuid) =>
                    context.emit(name: 'open-node', values: {'uuid': nodeUuid}),
              ),
      ),
    );
    return Builder(
      builder: (targetContext) => DragTarget<String>(
        onWillAcceptWithDetails: (details) => details.data != uuid,
        onAcceptWithDetails: (details) {
          final box = targetContext.findRenderObject()! as RenderBox;
          final localY = box.globalToLocal(details.offset).dy;
          context.emit(
            name: 'drop',
            values: {
              'uuid': uuid,
              'placement': androidOutlinerDropPlacement(
                localY,
                box.size.height,
              ),
            },
          );
        },
        builder: (_, candidates, _) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: candidates.isEmpty
                ? Colors.transparent
                : Theme.of(buildContext).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Semantics(
            key: ValueKey('outliner-block-content-$uuid'),
            container: true,
            explicitChildNodes: true,
            label: 'Edit block ${title.isEmpty ? 'Untitled block' : title}',
            button: true,
            child: LongPressDraggable<String>(
              data: uuid,
              dragAnchorStrategy: pointerDragAnchorStrategy,
              onDragStarted: () =>
                  context.emit(name: 'drag-start', values: {'uuid': uuid}),
              feedback: Material(
                elevation: 6,
                color: Theme.of(buildContext).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Text(title.isEmpty ? 'Untitled block' : title),
                  ),
                ),
              ),
              childWhenDragging: Opacity(opacity: 0.35, child: row),
              child: row,
            ),
          ),
        ),
      ),
    );
  }
}

String androidOutlinerDropPlacement(double localY, double rowHeight) {
  final height = rowHeight <= 0 ? 1.0 : rowHeight;
  if (localY < height * 0.25) return 'before';
  if (localY > height * 0.75) return 'after';
  return 'inside';
}

final class _ProjectedAsset extends StatelessWidget {
  const _ProjectedAsset({
    required this.title,
    required this.assetType,
    required this.localPath,
  });

  final String title;
  final String assetType;
  final String localPath;

  @override
  Widget build(BuildContext context) {
    if (isAndroidImageAsset(assetType, localPath) && localPath.isNotEmpty) {
      return Semantics(
        key: const ValueKey('asset.preview.image'),
        identifier: 'asset.preview.image',
        label: title,
        image: true,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            File(localPath),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _fallback(),
          ),
        ),
      );
    }
    if (localPath.isNotEmpty && isAndroidAudioAsset(assetType, localPath)) {
      return AndroidAudioPlayer(title: title, path: localPath);
    }
    return _fallback();
  }

  Widget _fallback() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(Icons.attach_file_rounded),
      const SizedBox(width: 8),
      Flexible(child: Text(title)),
    ],
  );
}

bool isAndroidImageAsset(String assetType, String localPath) {
  final normalizedType = assetType.toLowerCase().split(';').first.trim();
  if (normalizedType.startsWith('image/')) return true;
  const imageExtensions = {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'wbmp',
    'heic',
    'heif',
    'avif',
  };
  if (imageExtensions.contains(normalizedType)) return true;
  final dot = localPath.lastIndexOf('.');
  if (dot < 0 || dot == localPath.length - 1) return false;
  return imageExtensions.contains(localPath.substring(dot + 1).toLowerCase());
}

final class _ProjectedMarkup extends StatelessWidget {
  const _ProjectedMarkup({
    required this.encoded,
    required this.fallback,
    required this.youtubeTargetUrl,
    required this.youtubePlayback,
    required this.onOpenNode,
  });

  final String encoded;
  final String fallback;
  final String youtubeTargetUrl;
  final _YoutubePlaybackCoordinator youtubePlayback;
  final ValueChanged<String> onOpenNode;

  @override
  Widget build(BuildContext context) {
    final nodes = _decode();
    if (nodes.isEmpty) return Text(fallback);
    return ValueListenableBuilder<Map<String, int>>(
      valueListenable: youtubePlayback,
      builder: (context, playbackStarts, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (index, chunk) in _chunks(nodes).indexed)
            _chunk(context, chunk, index, playbackStarts),
        ],
      ),
    );
  }

  Widget _chunk(
    BuildContext context,
    List<Map<String, Object?>> chunk,
    int index,
    Map<String, int> playbackStarts,
  ) {
    if (chunk.length == 1 && _isRich(chunk.first)) {
      final node = chunk.first;
      final identifier = _richIdentifier(node, playbackStarts);
      return Semantics(
        key: ValueKey(identifier),
        identifier: identifier,
        container: true,
        child: _node(context, node),
      );
    }
    final identifier = 'block.rich.inline.$index';
    return Semantics(
      key: ValueKey(identifier),
      identifier: identifier,
      container: true,
      explicitChildNodes: true,
      label: _plainText(chunk),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [for (final node in chunk) _node(context, node)],
      ),
    );
  }

  List<List<Map<String, Object?>>> _chunks(List<Map<String, Object?>> nodes) {
    final result = <List<Map<String, Object?>>>[];
    var inline = <Map<String, Object?>>[];
    for (final node in nodes) {
      if (_isRich(node)) {
        if (inline.isNotEmpty) result.add(inline);
        inline = <Map<String, Object?>>[];
        result.add([node]);
      } else {
        inline.add(node);
      }
    }
    if (inline.isNotEmpty) result.add(inline);
    return result;
  }

  bool _isRich(Map<String, Object?> node) => const {
    'quote',
    'math',
    'codeBlock',
    'video',
    'iframe',
    'youtubeTimestamp',
    'cloze',
  }.contains(node['type']);

  String _richIdentifier(
    Map<String, Object?> node,
    Map<String, int> playbackStarts,
  ) {
    final type = node['type'] as String? ?? 'text';
    if (type == 'video') {
      final start = playbackStarts[node['url'] as String? ?? ''];
      if (start != null) return 'block.rich.video.start.$start';
    } else if (type == 'youtubeTimestamp') {
      final seconds = int.tryParse(node['style'] as String? ?? '');
      if (seconds != null && playbackStarts[youtubeTargetUrl] == seconds) {
        return 'block.rich.youtubeTimestamp.start.$seconds';
      }
    }
    return 'block.rich.$type';
  }

  List<Map<String, Object?>> _decode() {
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List<Object?>) return const [];
      return [
        for (final node in decoded)
          if (node is Map<String, Object?>) node,
      ];
    } catch (_) {
      return const [];
    }
  }

  Widget _node(BuildContext context, Map<String, Object?> node) {
    final type = node['type'] as String? ?? 'text';
    final text = node['text'] as String? ?? '';
    final title = node['title'] as String? ?? '';
    final url = node['url'] as String? ?? '';
    final children = _children(node);
    switch (type) {
      case 'emphasis':
        return DefaultTextStyle.merge(
          style: _emphasisStyle(node['style'] as String?),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [for (final child in children) _node(context, child)],
          ),
        );
      case 'code':
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(text, style: const TextStyle(fontFamily: 'monospace')),
        );
      case 'codeBlock':
        final language = node['style'] as String? ?? '';
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (language.isNotEmpty) ...[
                Text(
                  language,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 6),
              ],
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SelectableText.rich(
                  _highlightedCodeSpan(context, text, language),
                ),
              ),
            ],
          ),
        );
      case 'quote':
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                width: 3,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          child: DefaultTextStyle.merge(
            style: const TextStyle(fontStyle: FontStyle.italic),
            child: Wrap(
              children: [for (final child in children) _node(context, child)],
            ),
          ),
        );
      case 'nodeReference':
      case 'tagReference':
        final nodeUuid = node['uuid'] as String? ?? '';
        final label = type == 'tagReference' ? '#$title' : title;
        final identifier =
            'link.${type == 'tagReference' ? 'tag' : 'node'}.$nodeUuid';
        final openNode = nodeUuid.isEmpty ? null : () => onOpenNode(nodeUuid);
        return Semantics(
          key: ValueKey(identifier),
          identifier: identifier,
          container: true,
          link: true,
          label: label,
          onTap: openNode,
          child: ExcludeSemantics(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: openNode,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  label,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
          ),
        );
      case 'link':
        return Text(
          children.isEmpty ? url : _plainText(children),
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            decoration: TextDecoration.underline,
          ),
        );
      case 'youtubeTimestamp':
        final seconds = int.tryParse(node['style'] as String? ?? '');
        return InkWell(
          onTap: seconds == null || youtubeTargetUrl.isEmpty
              ? null
              : () => youtubePlayback.seek(youtubeTargetUrl, seconds),
          child: SizedBox(width: double.infinity, child: Text('◷ $text')),
        );
      case 'video':
        return AndroidEmbeddedMedia(
          url: url,
          startSeconds: youtubePlayback.value[url],
        );
      case 'iframe':
        return AndroidEmbeddedMedia(url: url, isVideo: false);
      case 'cloze':
        return AndroidCloze(text: text);
      case 'math':
        return AndroidMath(expression: text);
      default:
        return Text(text);
    }
  }

  TextSpan _highlightedCodeSpan(
    BuildContext context,
    String code,
    String language,
  ) {
    final brightness = Theme.of(context).brightness;
    final baseStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
      color: Theme.of(context).colorScheme.onSurface,
      height: 1.45,
    );
    final normalizedLanguage = _normalizedCodeLanguage(language);
    final cacheKey = '$normalizedLanguage\u0000$code';
    final nodes =
        _syntaxNodeCache[cacheKey] ??
        () {
          final parsed =
              syntax.highlight
                  .parse(code, language: normalizedLanguage)
                  .nodes ??
              const <syntax.Node>[];
          if (_syntaxNodeCache.length >= _syntaxNodeCacheLimit) {
            _syntaxNodeCache.remove(_syntaxNodeCache.keys.first);
          }
          _syntaxNodeCache[cacheKey] = parsed;
          return parsed;
        }();

    TextSpan span(syntax.Node node) {
      final children = node.children;
      return TextSpan(
        text: node.value,
        style: _syntaxStyle(node.className, brightness),
        children: children == null
            ? null
            : [for (final child in children) span(child)],
      );
    }

    return TextSpan(
      style: baseStyle,
      children: [for (final node in nodes) span(node)],
    );
  }

  String _normalizedCodeLanguage(String language) =>
      switch (language.trim().toLowerCase()) {
        'clj' || 'cljs' || 'cljc' => 'clojure',
        'js' => 'javascript',
        'ts' => 'typescript',
        'sh' || 'zsh' => 'shell',
        'py' => 'python',
        'rb' => 'ruby',
        'yml' => 'yaml',
        'c#' => 'cs',
        'objective-c' || 'objc' => 'objectivec',
        '' => 'plaintext',
        final value => value,
      };

  TextStyle? _syntaxStyle(String? token, Brightness brightness) {
    if (token == null) return null;
    final dark = brightness == Brightness.dark;
    final color = switch (token) {
      'comment' ||
      'quote' => dark ? const Color(0xff8b949e) : const Color(0xff6e7781),
      'keyword' ||
      'selector-tag' ||
      'addition' => dark ? const Color(0xffff7b72) : const Color(0xffcf222e),
      'number' || 'literal' || 'variable' || 'template-variable' =>
        dark ? const Color(0xff79c0ff) : const Color(0xff0550ae),
      'string' ||
      'doctag' ||
      'regexp' => dark ? const Color(0xffa5d6ff) : const Color(0xff0a3069),
      'title' || 'section' || 'name' || 'selector-id' || 'selector-class' =>
        dark ? const Color(0xffd2a8ff) : const Color(0xff8250df),
      'type' ||
      'class' ||
      'built_in' ||
      'builtin-name' ||
      'attribute' => dark ? const Color(0xff7ee787) : const Color(0xff116329),
      'meta' ||
      'symbol' ||
      'bullet' ||
      'link' => dark ? const Color(0xffffa657) : const Color(0xff953800),
      'deletion' => dark ? const Color(0xffff7b72) : const Color(0xffcf222e),
      _ => null,
    };
    if (color == null) return null;
    return TextStyle(
      color: color,
      fontStyle: token == 'comment' ? FontStyle.italic : null,
      fontWeight: token == 'keyword' ? FontWeight.w600 : null,
    );
  }

  List<Map<String, Object?>> _children(Map<String, Object?> node) {
    final children = node['children'];
    if (children is! List<Object?>) return const [];
    return [
      for (final child in children)
        if (child is Map<String, Object?>) child,
    ];
  }

  String _plainText(List<Map<String, Object?>> nodes) => nodes.map((node) {
    final type = node['type'];
    if (type == 'nodeReference') return node['title'] as String? ?? '';
    if (type == 'tagReference') return '#${node['title'] as String? ?? ''}';
    final children = _children(node);
    return children.isEmpty
        ? (node['text'] as String? ?? node['url'] as String? ?? '')
        : _plainText(children);
  }).join();

  TextStyle? _emphasisStyle(String? style) => switch (style) {
    'bold' => const TextStyle(fontWeight: FontWeight.bold),
    'italic' => const TextStyle(fontStyle: FontStyle.italic),
    'underline' => const TextStyle(decoration: TextDecoration.underline),
    'strikeThrough' => const TextStyle(decoration: TextDecoration.lineThrough),
    _ => null,
  };
}

final class _OutlinerEditor extends StatefulWidget {
  const _OutlinerEditor({required this.context});

  final LUIFlutterExtensionContext context;

  @override
  State<_OutlinerEditor> createState() => _OutlinerEditorState();
}

final class _OutlinerEditorState extends State<_OutlinerEditor> {
  static const _textChangeDelay = Duration(milliseconds: 80);

  late final TextEditingController _controller;
  late String _observedText;
  late String _previousText;
  late String _modelTitle;
  final _publishedTitles = <String>[];
  late int _modelCaret;
  late TextSelection _observedSelection;
  late TextSelection _previousSelection;
  var _wasComposing = false;
  var _applyingModel = false;
  Timer? _textChangeTimer;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.context.property('title')! as String,
    );
    _restoreSelection();
    _observedText = _controller.text;
    _previousText = _modelTitle = _controller.text;
    _modelCaret = widget.context.property('caret-utf16-offset')! as int;
    _previousSelection = _observedSelection = _controller.selection;
    _controller.addListener(_observeController);
  }

  @override
  void didUpdateWidget(covariant _OutlinerEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final title = widget.context.property('title')! as String;
    final caret = widget.context.property('caret-utf16-offset')! as int;
    final titleChanged = title != _modelTitle;
    final caretChanged = caret != _modelCaret;
    _modelTitle = title;
    _modelCaret = caret;
    // Model acknowledgements can arrive after another edit or caret movement.
    final acknowledged = _publishedTitles.indexOf(title);
    if (acknowledged >= 0) {
      _publishedTitles.removeRange(0, acknowledged + 1);
      return;
    }
    if (titleChanged || (caretChanged && _controller.text == title)) {
      if (titleChanged) _publishedTitles.clear();
      _applyingModel = true;
      try {
        if (_controller.text != title) {
          _textChangeTimer?.cancel();
          _controller.text = title;
        }
        _restoreSelection();
        _rememberControllerValue();
      } finally {
        _applyingModel = false;
      }
    }
  }

  void _restoreSelection() {
    final requested = widget.context.property('caret-utf16-offset')! as int;
    final offset = requested.clamp(0, _controller.text.length);
    _controller.selection = TextSelection.collapsed(offset: offset);
  }

  int get _caret {
    final offset = _controller.selection.baseOffset;
    return offset < 0 ? _controller.text.length : offset;
  }

  void _observeController() {
    if (_applyingModel) return;
    final selection = _controller.selection;
    final textChanged = _controller.text != _observedText;
    final selectionChanged = selection != _observedSelection;
    final composing =
        _controller.value.isComposingRangeValid &&
        !_controller.value.composing.isCollapsed;
    final committed = _wasComposing && !composing;
    _wasComposing = composing;
    if (textChanged) {
      _previousText = _observedText;
      _previousSelection = _observedSelection;
    }
    _rememberControllerValue();
    if (committed && !textChanged) _handleTextChanged(_controller.text);
    if (!textChanged && selectionChanged && selection.baseOffset >= 0) {
      widget.context.emit(
        name: 'caret-change',
        values: {'caret-utf16-offset': selection.baseOffset},
      );
    }
  }

  void _rememberControllerValue() {
    _observedText = _controller.text;
    _observedSelection = _controller.selection;
  }

  void _handleTextChanged(String title) {
    if (_controller.value.isComposingRangeValid &&
        !_controller.value.composing.isCollapsed) {
      _textChangeTimer?.cancel();
      return;
    }
    final newline = _caret - 1;
    final singleInsertion =
        title.length == _previousText.length + 1 &&
        newline >= 0 &&
        newline < title.length &&
        title[newline] == '\n' &&
        title.replaceRange(newline, newline + 1, '') == _previousText;
    final replacedSelection =
        _previousSelection.isValid &&
        !_previousSelection.isCollapsed &&
        _previousText.replaceRange(
              _previousSelection.start,
              _previousSelection.end,
              '\n',
            ) ==
            title;
    if ((singleInsertion || replacedSelection) &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _textChangeTimer?.cancel();
      final submitted = title.replaceRange(newline, newline + 1, '');
      final caret = newline.clamp(0, submitted.length);
      _applyingModel = true;
      try {
        _controller.value = TextEditingValue(
          text: submitted,
          selection: TextSelection.collapsed(offset: caret),
        );
        _rememberControllerValue();
      } finally {
        _applyingModel = false;
      }
      _publishedTitles.add(submitted);
      widget.context.emit(
        name: 'return',
        values: {'title': submitted, 'caret-utf16-offset': caret},
      );
      return;
    }
    final caret = _caret;
    _textChangeTimer?.cancel();
    _textChangeTimer = Timer(_textChangeDelay, () {
      if (!mounted) return;
      _publishedTitles.add(title);
      widget.context.emit(
        name: 'text-change',
        values: {'title': title, 'caret-utf16-offset': caret},
      );
    });
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.backspace) {
      return KeyEventResult.ignored;
    }
    final selection = _controller.selection;
    if (!selection.isValid || !selection.isCollapsed || selection.start != 0) {
      return KeyEventResult.ignored;
    }
    _emitStructuralBackspace();
    return KeyEventResult.handled;
  }

  void _emitStructuralBackspace() {
    widget.context.emit(
      name: 'backspace',
      values: {'title': _controller.text, 'selection-length': 0},
    );
  }

  @override
  Widget build(BuildContext context) {
    final extension = widget.context;
    final blockId = extension.property('block-id')! as String;
    return Focus(
      onKeyEvent: _handleKeyEvent,
      child: Semantics(
        key: ValueKey('outliner-editor-$blockId'),
        identifier: 'field.outliner.block.$blockId',
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLines: null,
          style: Theme.of(context).textTheme.bodyMedium,
          textInputAction: TextInputAction.newline,
          inputFormatters: [
            _StructuralBackspaceFormatter(_emitStructuralBackspace),
          ],
          decoration: const InputDecoration(
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
            isDense: true,
            isCollapsed: true,
            contentPadding: EdgeInsets.zero,
          ),
          onChanged: _handleTextChanged,
          onSubmitted: (title) => extension.emit(
            name: 'return',
            values: {'title': title, 'caret-utf16-offset': _caret},
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _textChangeTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }
}

final class _StructuralBackspaceFormatter extends TextInputFormatter {
  _StructuralBackspaceFormatter(this.onStructuralBackspace);

  final VoidCallback onStructuralBackspace;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (oldValue.text == newValue.text &&
        oldValue.selection.isValid &&
        oldValue.selection.isCollapsed &&
        oldValue.selection.start == 0 &&
        newValue.selection == oldValue.selection) {
      onStructuralBackspace();
    }
    return newValue;
  }
}
