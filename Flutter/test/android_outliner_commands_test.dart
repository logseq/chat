import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/android_outliner_commands.dart';
import 'package:logseq_chat_flutter/android_imported_asset.dart';
import 'package:logseq_chat_flutter/android_platform_effects.dart';

void main() {
  test('delivers each outliner command revision exactly once', () async {
    final batches = <OutlinerPlatformCommandBatch>[];
    final dispatcher = OutlinerPlatformCommandDispatcher(batches.add);
    final response = jsonEncode({
      'ok': true,
      'result': {
        'outlinerCommandRevision': 7,
        'graphName': 'E2E Graph',
        'outlinerCommands': [
          {
            'type': 'confirmDelete',
            'uuids': ['first', 'second'],
          },
        ],
      },
    });

    await dispatcher.deliver(response);
    await dispatcher.deliver(response);

    expect(batches, hasLength(1));
    expect(batches.single.revision, 7);
    expect(batches.single.graphName, 'E2E Graph');
    expect(batches.single.commands.single.type, 'confirmDelete');
    expect(batches.single.commands.single.uuids, ['first', 'second']);
  });

  testWidgets('confirms block deletion with a native Material dialog', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final events = <Map<String, Object?>>[];
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigatorKey, home: const SizedBox()),
    );
    final handler = AndroidOutlinerPlatformCommandHandler(
      navigatorKey: navigatorKey,
      platform: _RecordingPlatformServices(),
      sendOutlinerEvent: (event) async => events.add(event),
      presentAttachment: (_, _) async {},
      presentAudioRecording: (_) async {},
    );
    final completed = handler.handle(
      const OutlinerPlatformCommandBatch(
        revision: 1,
        graphName: 'E2E Graph',
        commands: [
          OutlinerPlatformCommand(
            type: 'confirmDelete',
            uuids: ['first', 'second'],
          ),
        ],
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('Delete blocks?'), findsOneWidget);
    expect(
      find.text('This deletes the blocks and all of their children.'),
      findsOneWidget,
    );
    final cancel = find.byKey(
      const ValueKey('button.outliner-delete.cancel'),
    );
    final confirm = find.byKey(
      const ValueKey('button.outliner-delete.confirm'),
    );
    expect(cancel, findsOneWidget);
    expect(confirm, findsOneWidget);
    expect(
      tester.getSemantics(cancel).getSemanticsData().identifier,
      'button.outliner-delete.cancel',
    );
    expect(
      tester.getSemantics(confirm).getSemanticsData().identifier,
      'button.outliner-delete.confirm',
    );
    final confirmButton = tester.widget<TextButton>(
      find.descendant(of: confirm, matching: find.byType(TextButton)),
    );
    expect(
      confirmButton.style?.foregroundColor?.resolve({}),
      Theme.of(navigatorKey.currentContext!).colorScheme.error,
    );
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    await completed;

    expect(events, [
      {'type': 'confirmDelete'},
    ]);
  });

  test('maps clipboard commands to Android platform services', () async {
    final platform = _RecordingPlatformServices();
    final handler = AndroidOutlinerPlatformCommandHandler(
      navigatorKey: GlobalKey<NavigatorState>(),
      platform: platform,
      sendOutlinerEvent: (_) async {},
      presentAttachment: (_, _) async {},
      presentAudioRecording: (_) async {},
    );

    await handler.handle(
      const OutlinerPlatformCommandBatch(
        revision: 1,
        graphName: 'Work',
        commands: [
          OutlinerPlatformCommand(
            type: 'setClipboardReferences',
            uuids: ['a', 'b'],
          ),
          OutlinerPlatformCommand(type: 'setClipboardURLs', uuids: ['c']),
        ],
      ),
    );

    expect(platform.copied, ['[[a]]\n[[b]]', 'logseq://graph/Work?block-id=c']);
  });

  test(
    'never routes the Audio recording command through a file picker',
    () async {
      final platform = _RecordingPlatformServices();
      final recordingTargets = <String?>[];
      final handler = AndroidOutlinerPlatformCommandHandler(
        navigatorKey: GlobalKey<NavigatorState>(),
        platform: platform,
        sendOutlinerEvent: (_) async {},
        presentAttachment: (_, _) async {},
        presentAudioRecording: (target) async => recordingTargets.add(target),
      );

      await handler.handle(
        const OutlinerPlatformCommandBatch(
          revision: 1,
          graphName: 'Work',
          commands: [
            OutlinerPlatformCommand(type: 'recordAudio', uuid: 'block-a'),
          ],
        ),
      );

      expect(platform.presentedAttachments, isEmpty);
      expect(recordingTargets, ['block-a']);
    },
  );

  test('imports picked files into the command target block', () async {
    final imported = <({String kind, String? targetBlockId})>[];
    final handler = AndroidOutlinerPlatformCommandHandler(
      navigatorKey: GlobalKey<NavigatorState>(),
      platform: _RecordingPlatformServices(),
      sendOutlinerEvent: (_) async {},
      presentAttachment: (kind, targetBlockId) async {
        imported.add((kind: kind, targetBlockId: targetBlockId));
      },
      presentAudioRecording: (_) async {},
    );

    await handler.handle(
      const OutlinerPlatformCommandBatch(
        revision: 1,
        graphName: 'Work',
        commands: [
          OutlinerPlatformCommand(type: 'pickAttachment', uuid: 'block-a'),
          OutlinerPlatformCommand(type: 'takePhoto', uuid: 'block-b'),
        ],
      ),
    );

    expect(imported, [
      (kind: 'files', targetBlockId: 'block-a'),
      (kind: 'camera', targetBlockId: 'block-b'),
    ]);
  });

  test('imported assets produce the core addAsset request', () {
    final asset = AndroidImportedAsset.fromMap({
      'uuid': 'asset-a',
      'title': 'Photo.jpg',
      'assetType': 'image/jpeg',
      'size': 123,
      'checksum': 'abc123',
      'localPath': 'Assets/asset-a-Photo.jpg',
    });

    expect(asset.coreRequest(targetBlockId: 'block-a'), {
      'apiVersion': 1,
      'method': 'dispatch',
      'params': {
        'action': 'addAsset',
        'payload': jsonEncode({
          'uuid': 'asset-a',
          'title': 'Photo.jpg',
          'assetType': 'image/jpeg',
          'assetSize': 123,
          'assetChecksum': 'abc123',
          'localPath': 'Assets/asset-a-Photo.jpg',
          'targetBlockId': 'block-a',
        }),
      },
    });
  });
}

final class _RecordingPlatformServices extends AndroidPlatformServices {
  final copied = <String>[];
  final presentedAttachments = <String>[];

  @override
  Future<void> copyText(String text) async => copied.add(text);

  @override
  Future<bool> presentAttachment(String kind) async {
    presentedAttachments.add(kind);
    return true;
  }
}
