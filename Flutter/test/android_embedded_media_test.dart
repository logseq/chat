import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/android_embedded_media.dart';

void main() {
  test('builds safe YouTube embed URLs with timestamp parity', () {
    expect(
      androidEmbeddedMediaUri(
        'https://youtu.be/dQw4w9WgXcQ',
        startSeconds: 83,
      ).toString(),
      'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?playsinline=1&start=83',
    );
    expect(
      androidEmbeddedMediaUri('https://www.youtube.com/watch?v=dQw4w9WgXcQ')
          .toString(),
      'https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?playsinline=1',
    );
    expect(
      androidEmbeddedMediaUri('https://example.com/video.mp4').toString(),
      'https://example.com/video.mp4',
    );
  });

  test('rejects unsafe or malformed embedded media URLs', () {
    expect(androidEmbeddedMediaUri('javascript:alert(1)'), isNull);
    expect(androidEmbeddedMediaUri('file:///tmp/private'), isNull);
    expect(androidEmbeddedMediaUri('https://youtu.be/not valid'), isNull);
    expect(androidEmbeddedMediaUri(''), isNull);
  });

  testWidgets('does not create a platform view until the preview is tapped', (
    tester,
  ) async {
    final loaded = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AndroidEmbeddedMedia(
            url: 'https://youtu.be/dQw4w9WgXcQ',
            webViewBuilder: (uri) {
              loaded.add(uri);
              return const SizedBox(key: ValueKey('fake.webview'));
            },
          ),
        ),
      ),
    );

    expect(loaded, isEmpty);
    expect(find.text('Video preview'), findsOneWidget);
    expect(find.text('Tap to load'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('button.media.load')));
    await tester.pump();

    expect(find.byKey(const ValueKey('fake.webview')), findsOneWidget);
    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('media.webview.loaded')),
    );
    expect(semantics.identifier, 'media.webview.loaded');
    expect(loaded.single.host, 'www.youtube-nocookie.com');
  });
}
