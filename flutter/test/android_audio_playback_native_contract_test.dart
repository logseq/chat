import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android host provides native MediaPlayer playback methods', () {
    final player = File(
      'android/app/src/main/kotlin/com/logseq/chat/AndroidAudioPlayer.kt',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/logseq/logseq_chat_flutter/MainActivity.kt',
    ).readAsStringSync();

    expect(player, contains('MediaPlayer'));
    expect(player, contains('fun start(path: String)'));
    expect(player, contains('fun pause(sessionId: Int)'));
    expect(player, contains('fun resume(sessionId: Int)'));
    expect(player, contains('fun status(sessionId: Int)'));
    expect(player, contains('fun stop(sessionId: Int)'));
    expect(activity, contains('"startAudioPlayback"'));
    expect(activity, contains('"pauseAudioPlayback"'));
    expect(activity, contains('"resumeAudioPlayback"'));
    expect(activity, contains('"audioPlaybackStatus"'));
    expect(activity, contains('"stopAudioPlayback"'));
  });

  test('audio finalization stays off the Android main thread', () {
    final activity = File(
      'android/app/src/main/kotlin/com/logseq/logseq_chat_flutter/MainActivity.kt',
    ).readAsStringSync();

    expect(
      activity,
      contains(
        '"stopAudioRecording" -> withContext(Dispatchers.IO) {\n'
        '                            audioRecorder.stop()\n'
        '                        }',
      ),
    );
  });
}
