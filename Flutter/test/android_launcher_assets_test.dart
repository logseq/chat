import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Flutter owns a complete Android launcher asset set', () {
    const densities = ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'];
    const rasterNames = [
      'ic_launcher.png',
      'ic_launcher_background.png',
      'ic_launcher_foreground.png',
      'ic_launcher_monochrome.png',
    ];

    for (final density in densities) {
      for (final name in rasterNames) {
        final asset = File('android/app/src/main/res/mipmap-$density/$name');
        expect(asset.existsSync(), isTrue, reason: asset.path);
        expect(
          asset.readAsBytesSync().take(8),
          [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
          reason: '${asset.path} must be a PNG image',
        );
      }
    }

    for (final name in ['ic_launcher.xml', 'ic_launcher_round.xml']) {
      final adaptive = File('android/app/src/main/res/mipmap-anydpi-v26/$name');
      expect(adaptive.existsSync(), isTrue, reason: adaptive.path);
      final source = adaptive.readAsStringSync();
      expect(source, contains('@color/ic_launcher_background'));
      expect(source, contains('@drawable/ic_launcher_foreground'));
      expect(source, contains('@drawable/ic_launcher_monochrome'));
    }

    final foregroundFile = File(
      'android/app/src/main/res/drawable/ic_launcher_foreground.xml',
    );
    final foreground = foregroundFile.readAsStringSync();
    expect(foreground, contains('android:width="108dp"'));
    expect(foreground, contains('android:height="108dp"'));
    expect(foreground, contains('android:viewportWidth="108"'));
    expect(foreground, contains('android:viewportHeight="108"'));
    expect(foreground, contains('android:pivotX="54"'));
    expect(foreground, contains('android:pivotY="54"'));
    expect(foreground, contains('android:scaleX="0.86"'));
    expect(foreground, contains('android:scaleY="0.86"'));

    final monochrome = File(
      'android/app/src/main/res/drawable/ic_launcher_monochrome.xml',
    ).readAsStringSync();
    expect(monochrome, contains('android:strokeColor="#FF000000"'));
    expect(monochrome, contains('android:scaleX="0.86"'));
    expect(monochrome, contains('android:scaleY="0.86"'));

    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    expect(manifest, contains('android:roundIcon="@mipmap/ic_launcher_round"'));
    expect(manifest, contains('android.intent.action.SEND_MULTIPLE'));
    expect(manifest, contains('android:mimeType="*/*"'));
    expect(manifest, contains('android:scheme="logseqchat"'));
    expect(manifest, contains('android.app.shortcuts'));

    final shortcuts = File('android/app/src/main/res/xml/shortcuts.xml')
        .readAsStringSync();
    expect(shortcuts, contains('android:shortcutId="capture"'));
    expect(shortcuts, contains('android:shortcutId="journal"'));
    expect(shortcuts, contains('@drawable/ic_shortcut_capture'));
    expect(shortcuts, contains('@drawable/ic_shortcut_journal'));
    expect(shortcuts, contains('android:targetPackage="com.logseq.chat"'));
    expect(
      manifest,
      contains('android.permission.RECORD_AUDIO'),
      reason:
          'The Audio recording action needs the native microphone permission.',
    );

    final platformServices = File(
      'android/app/src/main/kotlin/com/logseq/chat/AndroidPlatformServices.kt',
    ).readAsStringSync();
    expect(
      platformServices,
      contains('ClipData.newPlainText("Logseq Chat", text)'),
    );
    expect(
      platformServices,
      contains('Intent.createChooser(intent, "Share from Logseq Chat")'),
    );

    final recorderFile = File(
      'android/app/src/main/kotlin/com/logseq/chat/AndroidAudioRecorder.kt',
    );
    expect(recorderFile.existsSync(), isTrue, reason: recorderFile.path);
    final recorder = recorderFile.readAsStringSync();
    expect(recorder, contains('MediaRecorder'));
    expect(recorder, contains('Manifest.permission.RECORD_AUDIO'));
    expect(recorder, contains('MessageDigest.getInstance("SHA-256")'));
    expect(recorder, contains('File(context.filesDir, "Assets")'));

    final activity = File(
      'android/app/src/main/kotlin/com/logseq/logseq_chat_flutter/MainActivity.kt',
    ).readAsStringSync();
    expect(activity, contains('"startAudioRecording"'));
    expect(activity, contains('"stopAudioRecording"'));
    expect(activity, contains('"cancelAudioRecording"'));

    final outlinerCommands = File('lib/android_outliner_commands.dart')
        .readAsStringSync();
    expect(outlinerCommands, contains('presentAudioRecording(command.uuid)'));

    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('showAndroidAudioRecordingSheet'));
    expect(main, contains('asset.coreRequest'));
  });
}
