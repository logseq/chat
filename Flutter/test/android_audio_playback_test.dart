import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/android_audio_playback.dart';

void main() {
  test('recognizes Android audio assets by MIME type or extension', () {
    expect(isAndroidAudioAsset('audio/mp4', ''), isTrue);
    expect(isAndroidAudioAsset('m4a', ''), isTrue);
    expect(isAndroidAudioAsset('', '/tmp/Voice.WAV'), isTrue);
    expect(isAndroidAudioAsset('image/jpeg', '/tmp/photo.jpg'), isFalse);
  });

  testWidgets('plays, pauses, and stops an inline audio asset', (tester) async {
    final backend = _FakeAudioPlaybackBackend();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AndroidAudioPlayer(
            title: 'Voice note.m4a',
            path: '/tmp/voice.m4a',
            backend: backend,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('player.asset.audio')), findsOneWidget);
    expect(find.text('Play audio'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('button.audio.play-pause')));
    await tester.pump();
    expect(backend.startedPaths, ['/tmp/voice.m4a']);
    expect(find.text('Pause audio'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('button.audio.play-pause')));
    await tester.pump();
    expect(backend.pausedSessions, [41]);
    expect(find.text('Play audio'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(backend.stoppedSessions, [41]);
  });

  testWidgets('shows playback failures without getting stuck', (tester) async {
    final backend = _FakeAudioPlaybackBackend(
      startError: Exception('bad file'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AndroidAudioPlayer(
            title: 'Broken audio',
            path: '/tmp/broken.m4a',
            backend: backend,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('button.audio.play-pause')));
    await tester.pump();

    expect(find.text('Could not play audio'), findsOneWidget);
    expect(find.text('Play audio'), findsOneWidget);
  });
}

final class _FakeAudioPlaybackBackend implements AndroidAudioPlaybackBackend {
  _FakeAudioPlaybackBackend({this.startError});

  final Object? startError;
  final List<String> startedPaths = [];
  final List<int> pausedSessions = [];
  final List<int> stoppedSessions = [];

  @override
  Future<AndroidAudioPlaybackSession> start(String path) async {
    startedPaths.add(path);
    if (startError case final error?) throw error;
    return const AndroidAudioPlaybackSession(
      id: 41,
      duration: Duration(seconds: 4),
    );
  }

  @override
  Future<void> pause(int sessionId) async => pausedSessions.add(sessionId);

  @override
  Future<void> resume(int sessionId) async {}

  @override
  Future<AndroidAudioPlaybackStatus> status(int sessionId) async =>
      const AndroidAudioPlaybackStatus(
        isActive: true,
        isPlaying: true,
        position: Duration(seconds: 1),
        duration: Duration(seconds: 4),
      );

  @override
  Future<void> stop(int sessionId) async => stoppedSessions.add(sessionId);
}
