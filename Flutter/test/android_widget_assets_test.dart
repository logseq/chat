import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ships native Android journal and capture widgets', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    expect(manifest, contains('.TodayJournalWidgetProvider'));
    expect(manifest, contains('.CaptureWidgetProvider'));
    expect(manifest, contains('@xml/today_journal_widget_info'));
    expect(manifest, contains('@xml/capture_widget_info'));

    final provider = File(
      'android/app/src/main/kotlin/com/logseq/chat/AndroidWidgets.kt',
    ).readAsStringSync();
    expect(provider, contains('logseqchat://journal'));
    expect(provider, contains('logseqchat://capture'));

    final capture = File(
      'android/app/src/main/res/layout/widget_capture.xml',
    ).readAsStringSync();
    expect(capture, contains('@drawable/ic_widget_capture'));
    expect(capture, isNot(contains('android:text="＋"')));

    for (final name in [
      'widget_today_journal.xml',
      'widget_capture.xml',
    ]) {
      final layout = File(
        'android/app/src/main/res/layout/$name',
      ).readAsStringSync();
      expect(layout, contains('@color/widget_on_surface'));
      expect(layout, contains('@color/widget_secondary'));
    }

    final night = File(
      'android/app/src/main/res/values-night/colors.xml',
    ).readAsStringSync();
    expect(night, contains('name="widget_background"'));
    expect(night, contains('name="widget_on_surface"'));
  });
}
