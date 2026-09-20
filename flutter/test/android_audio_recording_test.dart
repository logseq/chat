import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/android_audio_recording.dart';

void main() {
  const asset = RecordedAudioAsset(
    uuid: 'asset-a',
    title: 'Audio-2026-09-01 11-10-00.m4a',
    assetType: 'm4a',
    size: 2048,
    checksum: 'abc123',
    localPath: '/data/user/0/com.logseq.chat/files/Assets/Audio.m4a',
  );

  test('encodes a recorded asset through the authoritative core action', () {
    expect(asset.coreRequest(targetBlockId: 'block-a'), {
      'apiVersion': 1,
      'method': 'dispatch',
      'params': {
        'action': 'addAsset',
        'payload': jsonEncode({
          'uuid': 'asset-a',
          'title': 'Audio-2026-09-01 11-10-00.m4a',
          'assetType': 'm4a',
          'assetSize': 2048,
          'assetChecksum': 'abc123',
          'localPath': '/data/user/0/com.logseq.chat/files/Assets/Audio.m4a',
          'targetBlockId': 'block-a',
        }),
      },
    });
    final payload = jsonDecode(
      ((asset.coreRequest()['params']! as Map<String, Object?>)['payload']!
          as String),
    ) as Map<String, Object?>;
    expect(payload, isNot(contains('targetBlockId')));
  });

  test('encodes a transcript as a child of the recorded asset', () {
    expect(
      asset.transcriptCoreRequest(
        transcriptUuid: 'transcript-a',
        transcript: 'Recorded words',
      ),
      {
        'apiVersion': 1,
        'method': 'dispatch',
        'params': {
          'action': 'addChildBlock',
          'payload': jsonEncode({
            'uuid': 'transcript-a',
            'title': 'Recorded words',
            'parentId': 'asset-a',
          }),
        },
      },
    );
  });

  testWidgets('records and returns an audio asset from a Material sheet', (
    tester,
  ) async {
    final backend = _FakeAudioRecordingBackend(asset: asset);
    RecordedAudioRecordingResult? result;
    await tester.pumpWidget(
      _RecordingHarness(backend: backend, onResult: (value) => result = value),
    );

    await tester.tap(find.text('Open recorder'));
    await tester.pumpAndSettle();

    expect(backend.startCount, 1);
    expect(find.byKey(const ValueKey('sheet.audio-recording')), findsOneWidget);
    expect(find.text('Audio recording'), findsOneWidget);
    expect(find.text('Recording…'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('toggle.audio.transcription')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('button.audio.stop')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('button.audio.stop')));
    await tester.pumpAndSettle();

    expect(backend.stopCount, 1);
    expect(result?.asset, same(asset));
    expect(result?.transcriptionEnabled, isTrue);
    expect(find.byKey(const ValueKey('sheet.audio-recording')), findsNothing);
  });

  testWidgets('canceling a recording deletes it and returns no asset', (
    tester,
  ) async {
    final backend = _FakeAudioRecordingBackend(asset: asset);
    RecordedAudioRecordingResult? result = const RecordedAudioRecordingResult(
      asset: asset,
      transcriptionEnabled: true,
    );
    await tester.pumpWidget(
      _RecordingHarness(backend: backend, onResult: (value) => result = value),
    );

    await tester.tap(find.text('Open recorder'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('button.audio.cancel')));
    await tester.pumpAndSettle();

    expect(backend.cancelCount, 1);
    expect(result, isNull);
  });

  testWidgets('the transcription preference is returned with the recording', (
    tester,
  ) async {
    final backend = _FakeAudioRecordingBackend(asset: asset);
    RecordedAudioRecordingResult? result;
    await tester.pumpWidget(
      _RecordingHarness(backend: backend, onResult: (value) => result = value),
    );

    await tester.tap(find.text('Open recorder'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toggle.audio.transcription')));
    await tester.tap(find.byKey(const ValueKey('button.audio.stop')));
    await tester.pumpAndSettle();

    expect(result?.asset, same(asset));
    expect(result?.transcriptionEnabled, isFalse);
  });

  testWidgets('unsupported devices do not offer audio transcription', (
    tester,
  ) async {
    final backend = _FakeAudioRecordingBackend(
      asset: asset,
      transcriptionSupported: false,
    );
    RecordedAudioRecordingResult? result;
    await tester.pumpWidget(
      _RecordingHarness(backend: backend, onResult: (value) => result = value),
    );

    await tester.tap(find.text('Open recorder'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('toggle.audio.transcription')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('button.audio.stop')));
    await tester.pumpAndSettle();
    expect(result?.transcriptionEnabled, isFalse);
  });

  testWidgets('a microphone start failure stays visible and cannot be saved', (
    tester,
  ) async {
    final backend = _FakeAudioRecordingBackend(
      asset: asset,
      startError: StateError('Microphone access is required'),
    );
    await tester.pumpWidget(_RecordingHarness(backend: backend));

    await tester.tap(find.text('Open recorder'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Microphone access is required'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('button.audio.stop')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('a stop failure keeps the recorder open with a useful error', (
    tester,
  ) async {
    final backend = _FakeAudioRecordingBackend(
      asset: asset,
      stopError: StateError('The recording is empty'),
    );
    await tester.pumpWidget(_RecordingHarness(backend: backend));

    await tester.tap(find.text('Open recorder'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('button.audio.stop')));
    await tester.pumpAndSettle();

    expect(find.textContaining('The recording is empty'), findsOneWidget);
    expect(find.byKey(const ValueKey('sheet.audio-recording')), findsOneWidget);
  });
}

final class _RecordingHarness extends StatelessWidget {
  const _RecordingHarness({required this.backend, this.onResult});

  final AndroidAudioRecordingBackend backend;
  final ValueChanged<RecordedAudioRecordingResult?>? onResult;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final result = await showAndroidAudioRecordingSheet(
              context: context,
              backend: backend,
            );
            onResult?.call(result);
          },
          child: const Text('Open recorder'),
        ),
      ),
    ),
  );
}

final class _FakeAudioRecordingBackend implements AndroidAudioRecordingBackend {
  _FakeAudioRecordingBackend({
    required this.asset,
    this.startError,
    this.stopError,
    this.transcriptionSupported = true,
  });

  final RecordedAudioAsset asset;
  final Object? startError;
  final Object? stopError;
  final bool transcriptionSupported;
  var startCount = 0;
  var stopCount = 0;
  var cancelCount = 0;

  @override
  Future<bool> supportsTranscription() async => transcriptionSupported;

  @override
  Future<String> transcribe(String path) async => 'Recorded words';

  @override
  Future<void> start() async {
    startCount += 1;
    if (startError case final error?) throw error;
  }

  @override
  Future<RecordedAudioAsset> stop() async {
    stopCount += 1;
    if (stopError case final error?) throw error;
    return asset;
  }

  @override
  Future<void> cancel() async {
    cancelCount += 1;
  }
}
