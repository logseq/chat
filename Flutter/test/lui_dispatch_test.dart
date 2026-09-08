import 'package:flutter_test/flutter_test.dart';
import 'package:logseq_chat_flutter/lui_dispatch.dart';
import 'package:lui_flutter_backend/lui_flutter_backend.dart';

void main() {
  test('routes Material control events to the native LG bridge', () {
    final native = _RecordingNativeDispatch();

    dispatchLUIEvent(const LUIEvent.appear(node: 6), native);
    dispatchLUIEvent(const LUIEvent.press(node: 7), native);
    dispatchLUIEvent(
      const LUIEvent.textChanged(node: 8, text: 'Hello'),
      native,
    );
    dispatchLUIEvent(
      const LUIEvent.toggleChanged(node: 9, checked: true),
      native,
    );

    expect(native.events, [
      'appear:6',
      'press:7',
      'text:8:Hello',
      'toggle:9:true',
    ]);
  });

  test('preserves typed extension payloads', () {
    final native = _RecordingNativeDispatch();

    dispatchLUIEvent(
      const LUIEvent.extension(
        node: 11,
        identifier: 'outliner-block-content',
        name: 'edit',
        values: {'uuid': 'block-a'},
      ),
      native,
    );

    expect(native.events, [
      'extension:11:outliner-block-content:edit:block-a:0',
    ]);
  });
}

final class _RecordingNativeDispatch implements LogseqChatNativeDispatch {
  final events = <String>[];

  @override
  void appear(int node) => events.add('appear:$node');

  @override
  void change(int node) => events.add('change:$node');

  @override
  void dismiss(int node) => events.add('dismiss:$node');

  @override
  void doublePress(int node) => events.add('double:$node');

  @override
  void extensionEvent(
    int node,
    String identifier,
    String name,
    String text,
    int value,
  ) => events.add('extension:$node:$identifier:$name:$text:$value');

  @override
  void longPress(int node) => events.add('long:$node');

  @override
  void press(int node) => events.add('press:$node');

  @override
  void submit(int node) => events.add('submit:$node');

  @override
  void textChanged(int node, String text) => events.add('text:$node:$text');

  @override
  void toggleChanged(int node, bool checked) =>
      events.add('toggle:$node:$checked');

  @override
  void valueChanged(int node, double value) => events.add('value:$node:$value');
}
