import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'android_platform_effects.dart';

final class OutlinerPlatformCommand {
  const OutlinerPlatformCommand({
    required this.type,
    this.style,
    this.text,
    this.uuid,
    this.uuids = const [],
  });

  factory OutlinerPlatformCommand.fromJson(Map<String, Object?> value) {
    final uuids = value['uuids'];
    return OutlinerPlatformCommand(
      type: value['type'] as String? ?? '',
      style: value['style'] as String?,
      text: value['text'] as String?,
      uuid: value['uuid'] as String?,
      uuids: uuids is List<Object?>
          ? uuids.whereType<String>().toList(growable: false)
          : const [],
    );
  }

  final String type;
  final String? style;
  final String? text;
  final String? uuid;
  final List<String> uuids;
}

final class OutlinerPlatformCommandBatch {
  const OutlinerPlatformCommandBatch({
    required this.revision,
    required this.graphName,
    required this.commands,
    this.selectedBlockIds = const [],
  });

  final int revision;
  final String graphName;
  final List<OutlinerPlatformCommand> commands;
  final List<String> selectedBlockIds;
}

typedef OutlinerPlatformCommandBatchHandler = FutureOr<void> Function(
  OutlinerPlatformCommandBatch batch,
);

final class OutlinerPlatformCommandDispatcher {
  OutlinerPlatformCommandDispatcher(this.onBatch);

  final OutlinerPlatformCommandBatchHandler onBatch;
  var _lastRevision = 0;

  Future<void> deliver(String response) async {
    final batch = _decode(response);
    if (batch == null) {
      debugPrint('[OutlinerCommands] response did not contain a command batch');
      return;
    }
    debugPrint(
      '[OutlinerCommands] revision=${batch.revision} '
      'last=$_lastRevision selected=${batch.selectedBlockIds.join(',')} '
      'commands=${batch.commands.map((value) => value.type).join(',')}',
    );
    if (batch.revision <= _lastRevision) return;
    _lastRevision = batch.revision;
    if (batch.commands.isNotEmpty) await onBatch(batch);
  }

  static OutlinerPlatformCommandBatch? _decode(String response) {
    final Object? decoded;
    try {
      decoded = jsonDecode(response);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?> || decoded['ok'] != true) return null;
    final result = decoded['result'];
    if (result is! Map<String, Object?>) return null;
    final revision = result['outlinerCommandRevision'];
    final values = result['outlinerCommands'];
    if (revision is! int || values is! List<Object?>) return null;
    final outlinerState = result['outlinerState'];
    final selected = outlinerState is Map<String, Object?>
        ? outlinerState['selectedBlockIds']
        : null;
    return OutlinerPlatformCommandBatch(
      revision: revision,
      graphName: result['graphName'] as String? ?? '',
      commands: values
          .whereType<Map<String, Object?>>()
          .map(OutlinerPlatformCommand.fromJson)
          .where((command) => command.type.isNotEmpty)
          .toList(growable: false),
      selectedBlockIds: selected is List<Object?>
          ? selected.whereType<String>().toList(growable: false)
          : const [],
    );
  }
}

typedef SendOutlinerEvent = Future<void> Function(Map<String, Object?> event);
typedef PerformOutlinerHaptic = Future<void> Function(String? style);
typedef PresentAudioRecording = Future<void> Function(String? targetBlockId);
typedef PresentAttachment = Future<void> Function(
  String kind,
  String? targetBlockId,
);

final class AndroidOutlinerPlatformCommandHandler {
  AndroidOutlinerPlatformCommandHandler({
    required this.navigatorKey,
    required this.platform,
    required this.sendOutlinerEvent,
    required this.presentAttachment,
    required this.presentAudioRecording,
    PerformOutlinerHaptic? performHaptic,
  }) : performHaptic = performHaptic ?? _performHaptic;

  final GlobalKey<NavigatorState> navigatorKey;
  final AndroidPlatformServices platform;
  final SendOutlinerEvent sendOutlinerEvent;
  final PresentAttachment presentAttachment;
  final PresentAudioRecording presentAudioRecording;
  final PerformOutlinerHaptic performHaptic;

  Future<void> handle(OutlinerPlatformCommandBatch batch) async {
    for (final command in batch.commands) {
      switch (command.type) {
        case 'haptic':
          await performHaptic(command.style);
        case 'confirmDelete':
          await _confirmDeletion(command.uuids);
        case 'setClipboardText':
          await platform.copyText(command.text ?? '');
        case 'setClipboardReferences':
          await platform.copyText(
            command.uuids.map((uuid) => '[[$uuid]]').join('\n'),
          );
        case 'setClipboardURLs':
          await platform.copyText(
            command.uuids
                .map(
                  (uuid) => 'logseq://graph/${batch.graphName}?block-id=$uuid',
                )
                .join('\n'),
          );
        case 'pickAttachment':
          await presentAttachment('files', command.uuid);
        case 'takePhoto':
          await presentAttachment('camera', command.uuid);
        case 'recordAudio':
          await presentAudioRecording(command.uuid);
        case 'focusBlock':
          // The retained Android editor owns focus and uses autofocus when
          // the corresponding block editor is inserted into the tree.
          break;
      }
    }
  }

  Future<void> _confirmDeletion(List<String> blockIds) async {
    final context = navigatorKey.currentContext;
    debugPrint(
      '[OutlinerCommands] confirmDelete blocks=${blockIds.length} '
      'context=${context != null}',
    );
    if (context == null || blockIds.isEmpty) return;
    final plural = blockIds.length > 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(plural ? 'Delete blocks?' : 'Delete block?'),
        content: Text(
          plural
              ? 'This deletes the blocks and all of their children.'
              : 'This deletes the block and all of its children.',
        ),
        actions: [
          Semantics(
            key: const ValueKey('button.outliner-delete.cancel'),
            identifier: 'button.outliner-delete.cancel',
            button: true,
            child: TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
          ),
          Semantics(
            key: const ValueKey('button.outliner-delete.confirm'),
            identifier: 'button.outliner-delete.confirm',
            button: true,
            child: TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await sendOutlinerEvent(const {'type': 'confirmDelete'});
    }
  }

  static Future<void> _performHaptic(String? style) => switch (style) {
    'selection' => HapticFeedback.selectionClick(),
    _ => HapticFeedback.mediumImpact(),
  };
}
